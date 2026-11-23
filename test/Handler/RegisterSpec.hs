{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.RegisterSpec (spec) where

import TestImport
import Password (verifyUserPassword)
import Settings (AppSettings (..))
import qualified Data.Text as T

spec :: Spec
spec = withAppSettings (\settings -> settings { appAuthDummyLogin = False }) $ do
    describe "Registration and password authentication" $ do
        it "creates only students, hashes UTF-8 passwords and supports login/logout" $ do
            register "alice" "senha-segura-\x0100" "senha-segura-\x0100"
                [("role", "Administrator"), ("active", "false")]
            statusIs 303
            account <- runDB $ getBy $ UniqueUser "alice"
            user <- case account of
                Just (Entity _ registered) -> pure registered
                Nothing -> error "Expected a registered account"
            liftIO $ do
                userRole user `shouldBe` Student
                userActive user `shouldBe` True
                userPassword user `shouldNotBe` Just "senha-segura-\x0100"
                verifyUserPassword user "senha-segura-\x0100" `shouldBe` True
                verifyUserPassword user "senha-segura-\x0000" `shouldBe` False
            loginWithPassword "alice" "senha-segura-\x0100"
            statusIs 303
            get ProfileR
            statusIs 200
            htmlAnyContain ".username" "alice"
            get $ AuthR LogoutR
            statusIs 200
            request $ do
                setMethod "POST"
                setUrl $ AuthR LogoutR
                addToken
            statusIs 303
            get ProfileR
            statusIs 403

        it "reports duplicate registration without overwriting an account" $ do
            original <- createPasswordUser "alice" "original-password"
            register "alice" "different-password" "different-password" []
            statusIs 200
            htmlAnyContain "#message" "Este login ja esta cadastrado."
            persisted <- runDB $ getJust $ entityKey original
            liftIO $ userPassword persisted `shouldBe` userPassword (entityVal original)
            total <- runDB $ count ([] :: [Filter User])
            liftIO $ total `shouldBe` 1

        it "rejects short passwords, mismatched confirmation, blank names and invalid logins" $ do
            register "alice" "short" "short" []
            statusIs 200
            register "alice" "valid-password" "other-password" []
            statusIs 200
            htmlAnyContain "#message" "As senhas nao conferem."
            forM_ [("   ", "alice"), ("Alice", "invalid login")] $ \(name, ident) -> do
                get RegisterR
                request $ do
                    setMethod "POST"
                    setUrl RegisterR
                    addToken
                    addPostParam "name" name
                    addPostParam "username" ident
                    addPostParam "password" "valid-password"
                    addPostParam "confirmation" "valid-password"
                statusIs 200
            total <- runDB $ count ([] :: [Filter User])
            liftIO $ total `shouldBe` 0

        it "accepts 12 and 128 character passwords but rejects blank or longer passwords" $ do
            forM_ [("minimum", T.replicate 12 "x"), ("maximum", T.replicate 128 "x")] $ \(ident, password) -> do
                register ident password password []
                statusIs 303
                loginWithPassword ident password
                get ProfileR
                statusIs 200
                htmlAnyContain ".username" $ unpack ident
                request $ do
                    setMethod "POST"
                    setUrl $ AuthR LogoutR
                    addToken
            forM_ [T.replicate 12 " ", T.replicate 129 "x"] $ \password -> do
                register "rejected" password password []
                statusIs 200
            total <- runDB $ count ([] :: [Filter User])
            liftIO $ total `shouldBe` 2

        it "rejects registration and login without CSRF tokens" $ do
            get RegisterR
            request $ do
                setMethod "POST"
                setUrl RegisterR
                addPostParam "name" "Alice"
                addPostParam "username" "alice"
                addPostParam "password" "valid-password"
                addPostParam "confirmation" "valid-password"
            total <- runDB $ count ([] :: [Filter User])
            liftIO $ total `shouldBe` 0
            _ <- createPasswordUser "alice" "valid-password"
            get $ AuthR LoginR
            request $ do
                setMethod "POST"
                setUrl $ AuthR $ PluginR "password" []
                addPostParam "username" "alice"
                addPostParam "password" "valid-password"
            statusIs 403
            get ProfileR
            statusIs 403

        it "rejects invalid credentials, unknown users and accounts without passwords" $ do
            _ <- createPasswordUser "alice" "valid-password"
            _ <- createUser "legacy"
            forM_ [("alice", "wrong-password"), ("unknown", "valid-password"), ("legacy", "valid-password")] $ \(ident, password) -> do
                loginWithPassword ident password
                statusIs 303
                _ <- followRedirect
                htmlAnyContain "#message" "Invalid"
                get ProfileR
                statusIs 403
            total <- runDB $ count ([] :: [Filter User])
            liftIO $ total `shouldBe` 2

        it "rejects inactive accounts and denies access after an account becomes inactive" $ do
            Entity uid _ <- createPasswordUser "alice" "valid-password"
            loginWithPassword "alice" "valid-password"
            get ProfileR
            statusIs 200
            runDB $ update uid [UserActive =. False]
            get ProfileR
            statusIs 403
            loginWithPassword "alice" "valid-password"
            get ProfileR
            statusIs 403

        it "removes legacy OpenID login forms and endpoints while keeping password login" $ do
            get $ AuthR LoginR
            statusIs 200
            htmlCount "form" 1
            htmlCount "input[type=password]" 1
            get $ AuthR $ PluginR "openid" ["forward"]
            statusIs 404

        it "does not expose dummy login outside the test-only setting" $ do
            _ <- createUser "alice"
            get $ AuthR LoginR
            htmlCount "form[action$='/auth/page/dummy']" 0
            request $ do
                setMethod "POST"
                setUrl $ AuthR $ PluginR "dummy" []
                addPostParam "ident" "alice"
            statusIs 404
            get ProfileR
            statusIs 403

        it "promotes only an existing active password account through the controlled procedure" $ do
            Entity uid _ <- createPasswordUser "alice" "valid-password"
            Entity inactiveId _ <- createPasswordUser "inactive" "valid-password"
            _ <- createUser "legacy"
            runDB $ update inactiveId [UserActive =. False]
            results <- runDB $ mapM promoteUserToAdministrator ["missing", "legacy", "inactive", "alice", "alice"]
            liftIO $ results `shouldBe` [False, False, False, True, True]
            user <- runDB $ getJust uid
            liftIO $ userRole user `shouldBe` Administrator
            loginWithPassword "alice" "valid-password"
            get ProfileR
            statusIs 200
            htmlAnyContain ".user-role" "Administrador"

register :: Text -> Text -> Text -> [(Text, Text)] -> YesodExample App ()
register ident password confirmation extra = do
    get RegisterR
    request $ do
        setMethod "POST"
        setUrl RegisterR
        addToken
        addPostParam "name" "Alice"
        addPostParam "username" ident
        addPostParam "password" password
        addPostParam "confirmation" confirmation
        mapM_ (uncurry addPostParam) extra

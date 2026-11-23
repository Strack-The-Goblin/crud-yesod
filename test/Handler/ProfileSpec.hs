{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.ProfileSpec (spec) where

import TestImport
import Yesod.Core (setSession, toPathPiece)
import qualified Control.Exception as Exception
import Yesod.Core.Unsafe (fakeHandlerGetLogger)

spec :: Spec
spec = withApp $ do

    describe "Profile page" $ do
        it "asserts no access to my-account for anonymous users" $ do
            get ProfileR
            statusIs 403

        it "asserts access to my-account for authenticated users" $ do
            userEntity <- createUser "foo"
            authenticateAs userEntity

            get ProfileR
            statusIs 200

        it "asserts user's information is shown" $ do
            userEntity <- createUser "bar"
            authenticateAs userEntity

            get ProfileR
            let (Entity _ user) = userEntity
            htmlAnyContain ".username" . unpack $ userIdent user

        it "initializes a domain profile when authentication creates an account" $ do
            request $ do
                setMethod "POST"
                addPostParam "ident" "new-account"
                setUrl $ AuthR $ PluginR "dummy" []
            statusIs 303
            account <- runDB $ getBy $ UniqueUser "new-account"
            case account of
                Nothing -> liftIO $ expectationFailure "Authentication did not create an account"
                Just (Entity _ user) -> liftIO $ do
                    userName user `shouldBe` "new-account"
                    userRole user `shouldBe` Student
                    userActive user `shouldBe` True
                    userPassword user `shouldBe` Nothing
                    userPostalCode user `shouldBe` Nothing

        it "edits only the authenticated profile, ignoring forged identity and privilege fields" $ do
            alice@(Entity aliceId _) <- createUser "alice"
            Entity bobId bob <- createUser "bob"
            authenticateAs alice
            get ProfileR
            request $ do
                setMethod "POST"
                setUrl ProfileR
                addToken
                addPostParam "name" "Alice atualizada"
                addPostParam "postalCode" "01310100"
                addPostParam "street" "Avenida Paulista"
                addPostParam "neighborhood" "Bela Vista"
                addPostParam "city" "Sao Paulo"
                addPostParam "state" "SP"
                addPostParam "addressNumber" "100"
                addPostParam "addressComplement" "Sala 1"
                addPostParam "userId" $ toPathPiece bobId
                addPostParam "id" $ toPathPiece bobId
                addPostParam "ident" "bob"
                addPostParam "role" "Administrator"
                addPostParam "active" "false"
            statusIs 303
            updated <- runDB $ getJust aliceId
            unchanged <- runDB $ getJust bobId
            liftIO $ do
                userName updated `shouldBe` "Alice atualizada"
                userPostalCode updated `shouldBe` Just "01310100"
                userStreet updated `shouldBe` Just "Avenida Paulista"
                userNeighborhood updated `shouldBe` Just "Bela Vista"
                userCity updated `shouldBe` Just "Sao Paulo"
                userState updated `shouldBe` Just "SP"
                userAddressNumber updated `shouldBe` Just "100"
                userAddressComplement updated `shouldBe` Just "Sala 1"
                userIdent updated `shouldBe` "alice"
                userRole updated `shouldBe` Student
                userActive updated `shouldBe` True
                userName unchanged `shouldBe` userName bob
                userPostalCode unchanged `shouldBe` Nothing
            get ("/profile/" <> toPathPiece bobId :: Text)
            statusIs 404

        it "validates manual profile fields and requires CSRF for edits" $ do
            alice@(Entity uid _) <- createUser "alice"
            authenticateAs alice
            forM_ [[("name", "   ")], [("name", "Alice"), ("postalCode", "123")],
                   [("name", "Alice"), ("state", "XX")], [("name", "Alice"), ("street", "   ")]] $ \fields -> do
                get ProfileR
                request $ do
                    setMethod "POST"
                    setUrl ProfileR
                    addToken
                    mapM_ (uncurry addPostParam) fields
                statusIs 200
                user <- runDB $ getJust uid
                liftIO $ userName user `shouldBe` "alice"
            get ProfileR
            request $ do
                setMethod "POST"
                setUrl ProfileR
                addPostParam "name" "Forged"
            user <- runDB $ getJust uid
            liftIO $ userName user `shouldBe` "alice"

        it "allows a name-only profile and clearing the optional address" $ do
            alice@(Entity uid _) <- createUser "alice"
            runDB $ update uid [UserPostalCode =. Just "01310100", UserCity =. Just "Sao Paulo"]
            authenticateAs alice
            get ProfileR
            request $ do
                setMethod "POST"
                setUrl ProfileR
                addToken
                addPostParam "name" "Alice"
            statusIs 303
            user <- runDB $ getJust uid
            liftIO $ do
                userName user `shouldBe` "Alice"
                userPostalCode user `shouldBe` Nothing
                userCity user `shouldBe` Nothing

        it "enforces administrator and owner checks without an administrator ownership bypass" $ do
            alice@(Entity aliceId _) <- createUser "alice"
            Entity bobId _ <- createUser "bob"
            Entity adminId _ <- createUser "admin"
            runDB $ update adminId [UserRole =. Administrator]
            owner <- runHandler $ setSession credsKey (toPathPiece aliceId) >> requireOwner aliceId
            admin <- runHandler $ setSession credsKey (toPathPiece adminId) >> requireAdministrator
            liftIO $ do
                entityKey owner `shouldBe` entityKey alice
                entityKey admin `shouldBe` adminId
            app <- getTestYesod
            let denied uid action = liftIO $
                    fakeHandlerGetLogger appLogger app
                        (setSession credsKey (toPathPiece uid) >> action)
                    `shouldThrow` (\err -> "PermissionDenied" `isInfixOf` Exception.displayException (err :: Exception.SomeException))
            denied aliceId requireAdministrator
            denied bobId $ requireOwner aliceId
            denied adminId $ requireOwner aliceId

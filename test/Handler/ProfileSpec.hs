{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.ProfileSpec (spec) where

import TestImport

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

{-# LANGUAGE NoImplicitPrelude #-}
module Password (hashPassword, verifyUserPassword) where

import ClassyPrelude
import Model (User, userPassword)
import qualified Yesod.Auth.Util.PasswordStore as PasswordStore

hashPassword :: MonadIO m => Text -> m Text
hashPassword password =
    decodeUtf8 <$> liftIO (PasswordStore.makePassword (encodeUtf8 password) 19)

verifyUserPassword :: User -> Text -> Bool
verifyUserPassword user password =
    case userPassword user of
        Nothing -> False
        Just hashed -> PasswordStore.verifyPassword (encodeUtf8 password) (encodeUtf8 hashed)

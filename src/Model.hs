{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE DataKinds                  #-}
module Model where

import ClassyPrelude.Yesod
import Database.Persist.Quasi
import Database.Persist.Sql (rawExecute)

data UserRole = Student | Administrator
    deriving (Eq, Show, Read)

data LoanRequestStatus = Pending | Approved | Rejected | Cancelled | Collected
    deriving (Eq, Show, Read)

data EquipmentCondition = Good | Worn | Damaged
    deriving (Eq, Show, Read)

data InspectionKind = CheckoutInspection | ReturnInspection
    deriving (Eq, Show, Read)

derivePersistField "UserRole"
derivePersistField "LoanRequestStatus"
derivePersistField "EquipmentCondition"
derivePersistField "InspectionKind"

-- You can define all of your database entities in the entities file.
-- You can find more information on persistent and how to declare entities
-- at:
-- http://www.yesodweb.com/book/persistent/
share [mkPersist sqlSettings, mkMigrate "migrateAll"]
    $(persistFileWith lowerCaseSettings "config/models.persistentmodels")

newUser :: Text -> UTCTime -> User
newUser ident createdAt = User
    { userIdent = ident
    , userPassword = Nothing
    , userName = ident
    , userRole = Student
    , userActive = True
    , userPostalCode = Nothing
    , userStreet = Nothing
    , userNeighborhood = Nothing
    , userCity = Nothing
    , userState = Nothing
    , userAddressNumber = Nothing
    , userAddressComplement = Nothing
    , userCreatedAt = createdAt
    }

promoteUserToAdministrator :: MonadIO m => Text -> ReaderT SqlBackend m Bool
promoteUserToAdministrator ident = do
    account <- getBy $ UniqueUser ident
    case account of
        Just (Entity uid user) | userActive user && isJust (userPassword user) -> do
            update uid [UserRole =. Administrator]
            pure True
        _ -> pure False

migrateDatabase :: MonadIO m => ReaderT SqlBackend m ()
migrateDatabase = do
    runMigration migrateAll
    -- Existing accounts gain a display name without changing login or password.
    rawExecute "UPDATE \"user\" SET \"name\" = \"ident\" WHERE \"name\" = ''" []

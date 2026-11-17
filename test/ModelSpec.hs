{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module ModelSpec (spec) where

import TestImport
import qualified Control.Exception as Exception
import Data.Time (addUTCTime)
import Database.Persist.Sql (SqlPersistM, rawExecute, runSqlPersistMPool, toSqlKey)
import Database.PostgreSQL.Simple (SqlError (sqlState))

spec :: Spec
spec = withApp $ describe "Domain model" $ do
    it "persists the seven related entities, typed states and UTC timestamps" $ do
        (equipmentId, requestId, loanId, createdAt) <- createFixture
        equipment <- runDB $ getJust equipmentId
        owner <- runDB $ getJust $ equipmentOwnerId equipment
        category <- runDB $ getJust $ equipmentCategoryId equipment
        loanRequest <- runDB $ getJust requestId
        borrower <- runDB $ getJust $ loanRequestRequesterId loanRequest
        loan <- runDB $ getJust loanId
        inspections <- runDB $ selectList [InspectionLoanId ==. loanId]
            [Asc InspectionPerformedAt]
        maintenance <- runDB $ selectList [MaintenanceEquipmentId ==. equipmentId] []
        liftIO $ do
            userRole owner `shouldBe` Administrator
            userActive owner `shouldBe` True
            userCity owner `shouldBe` Just "Sao Paulo"
            userCreatedAt owner `shouldBe` createdAt
            userRole borrower `shouldBe` Student
            categoryName category `shouldBe` "Electronics"
            equipmentCondition equipment `shouldBe` Good
            equipmentCreatedAt equipment `shouldBe` createdAt
            loanRequestEquipmentId loanRequest `shouldBe` equipmentId
            loanRequestStatus loanRequest `shouldBe` Collected
            loanRequestStartsAt loanRequest `shouldBe` createdAt
            loanRequestEndsAt loanRequest `shouldBe` addUTCTime 7200 createdAt
            loanRequestCreatedAt loanRequest `shouldBe` createdAt
            loanRequestPurpose loanRequest `shouldBe` "Lab project"
            loanRequestRejectionReason loanRequest `shouldBe` Nothing
            loanRequestRequesterId loanRequest `shouldNotBe` equipmentOwnerId equipment
            loanSourceRequestId loan `shouldBe` requestId
            loanCheckedOutAt loan `shouldBe` createdAt
            loanDueAt loan `shouldBe` addUTCTime 7200 createdAt
            loanReturnedAt loan `shouldBe` Just (addUTCTime 3600 createdAt)
            map (inspectionKind . entityVal) inspections
                `shouldBe` [CheckoutInspection, ReturnInspection]
            map (inspectionCondition . entityVal) inspections `shouldBe` [Good, Damaged]
            map (inspectionInspectorId . entityVal) inspections
                `shouldBe` replicate 2 (equipmentOwnerId equipment)
            map (inspectionPerformedAt . entityVal) inspections
                `shouldBe` [createdAt, addUTCTime 3600 createdAt]
            map entityVal maintenance `shouldBe`
                [Maintenance equipmentId "Damaged cable" (addUTCTime 3600 createdAt)
                    Nothing Nothing]

    it "enforces unique categories and equipment identification scoped to owner" $ do
        (equipmentId, requestId, _, _) <- createFixture
        equipment <- runDB $ getJust equipmentId
        loanRequest <- runDB $ getJust requestId
        expectSqlState "23505" $ insert_ $ Category "Electronics" "Duplicate"
        expectSqlState "23505" $ insert_ equipment
        anotherId <- runDB $ insert equipment
            { equipmentOwnerId = loanRequestRequesterId loanRequest }
        liftIO $ anotherId `shouldNotBe` equipmentId

    it "allows only one loan per request and one inspection per kind" $ do
        (_, _, loanId, createdAt) <- createFixture
        loan <- runDB $ getJust loanId
        inspection <- runDB $ getBy $ UniqueLoanInspection loanId CheckoutInspection
        expectSqlState "23505" $ insert_ loan
        case inspection of
            Nothing -> liftIO $ expectationFailure "Missing checkout inspection"
            Just (Entity _ value) -> expectSqlState "23505" $ insert_ value
        runDB $ update loanId [LoanReturnedAt =. Just (addUTCTime 4000 createdAt)]
        updated <- runDB $ getJust loanId
        liftIO $ loanReturnedAt updated `shouldBe` Just (addUTCTime 4000 createdAt)

    it "rejects missing foreign keys and deletion of referenced records" $ do
        (equipmentId, requestId, loanId, createdAt) <- createFixture
        equipment <- runDB $ getJust equipmentId
        loanRequest <- runDB $ getJust requestId
        loan <- runDB $ getJust loanId
        expectSqlState "23503" $ insert_ equipment { equipmentOwnerId = toSqlKey (-1) }
        expectSqlState "23503" $ insert_ equipment
            { equipmentCategoryId = toSqlKey (-1), equipmentIdentification = "BAD-CATEGORY" }
        expectSqlState "23503" $ insert_ loanRequest
            { loanRequestEquipmentId = toSqlKey (-1) }
        expectSqlState "23503" $ insert_ loanRequest
            { loanRequestRequesterId = toSqlKey (-1) }
        expectSqlState "23503" $ insert_ loan { loanSourceRequestId = toSqlKey (-1) }
        expectSqlState "23503" $ insert_ $
            Inspection (toSqlKey (-1)) (equipmentOwnerId equipment)
                CheckoutInspection Good "" createdAt
        freshRequestId <- runDB $ insert loanRequest
        freshLoanId <- runDB $ insert loan { loanSourceRequestId = freshRequestId }
        expectSqlState "23503" $ insert_ $
            Inspection freshLoanId (toSqlKey (-1)) CheckoutInspection Good "" createdAt
        expectSqlState "23503" $ insert_ $
            Maintenance (toSqlKey (-1)) "Invalid equipment" createdAt Nothing Nothing
        expectSqlState "23001" $ delete $ equipmentOwnerId equipment
        expectSqlState "23001" $ delete $ equipmentCategoryId equipment
        expectSqlState "23001" $ delete equipmentId
        expectSqlState "23001" $ delete requestId
        expectSqlState "23001" $ delete loanId

    it "rejects null required fields at the database boundary" $
        expectSqlState "23502" $
            rawExecute "INSERT INTO category (name, description) VALUES (NULL, '')" []

    it "backfills legacy names without changing login, password or custom names" $ do
        legacy <- createUser "legacy"
        named <- createUser "named"
        runDB $ do
            update (entityKey legacy) [UserName =. "", UserPassword =. Just "test-hash"]
            update (entityKey named) [UserName =. "Existing display name"]
            migrateDatabase
            migrateDatabase
        legacyUser <- runDB $ getJust $ entityKey legacy
        namedUser <- runDB $ getJust $ entityKey named
        liftIO $ do
            userIdent legacyUser `shouldBe` "legacy"
            userName legacyUser `shouldBe` "legacy"
            userPassword legacyUser `shouldBe` Just "test-hash"
            userName namedUser `shouldBe` "Existing display name"

expectSqlState :: ByteString -> SqlPersistM a -> YesodExample App ()
expectSqlState expected action = do
    pool <- appConnPool <$> getTestYesod
    result <- liftIO $ Exception.try $ runSqlPersistMPool (void action) pool
    liftIO $ case result of
        Left err -> sqlState err `shouldBe` expected
        Right () -> expectationFailure "Expected a PostgreSQL constraint violation"

createFixture :: YesodExample App (EquipmentId, LoanRequestId, LoanId, UTCTime)
createFixture = do
    owner <- createUser "owner"
    borrower <- createUser "borrower"
    let createdAt = UTCTime (fromGregorian 2026 1 1) 0
        returnedAt = addUTCTime 3600 createdAt
        dueAt = addUTCTime 7200 createdAt
    runDB $ do
        update (entityKey owner)
            [ UserRole =. Administrator
            , UserCity =. Just "Sao Paulo"
            , UserCreatedAt =. createdAt
            ]
        categoryId <- insert $ Category "Electronics" "Lab equipment"
        equipmentId <- insert $ Equipment "Arduino kit" "Starter kit" "KIT-001"
            Good True (entityKey owner) categoryId createdAt
        requestId <- insert $ LoanRequest equipmentId (entityKey borrower)
            createdAt dueAt "Lab project" Collected Nothing createdAt
        loanId <- insert $ Loan requestId createdAt dueAt (Just returnedAt)
        insert_ $ Inspection loanId (entityKey owner) CheckoutInspection Good "" createdAt
        insert_ $ Inspection loanId (entityKey owner) ReturnInspection Damaged
            "Damaged cable" returnedAt
        insert_ $ Maintenance equipmentId "Damaged cable" returnedAt Nothing Nothing
        return (equipmentId, requestId, loanId, createdAt)

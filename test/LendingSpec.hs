{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module LendingSpec (spec) where

import TestImport hiding (first, second)
import Lending
import qualified Control.Exception as E
import Database.Persist.Sql (SqlPersistM, runSqlPersistMPool, rawExecute)
import Database.PostgreSQL.Simple (SqlError (..))
import Data.Time (addUTCTime, NominalDiffTime)
import qualified Data.Text as T
import qualified System.Timeout as Timeout
import qualified Database.Persist as DB

spec :: Spec
spec = withApp $ describe "Lending workflows" $ do
    it "requires administrator categories, complete owner address and owner-scoped unique equipment" $ do
        Entity ownerId _ <- createUser "owner"
        denied $ saveCategory ownerId Nothing "Tools" "Tools"
        runDB $ update ownerId [UserRole =. Administrator]
        cid <- runDB $ saveCategory ownerId Nothing "Tools" "Tools"
        denied $ saveEquipment ownerId Nothing "Kit" "Kit" "1" Good cid
        setAddress ownerId
        eid <- runDB $ saveEquipment ownerId Nothing "Kit" "Kit" "1" Good cid
        denied $ saveEquipment ownerId Nothing "Duplicate" "Kit" "1" Good cid
        denied $ saveCategory ownerId Nothing "Tools" "Duplicate"
        denied $ removeCategory ownerId cid
        runDB $ removeEquipment ownerId eid >> removeCategory ownerId cid

    it "validates future periods, forbids own/inactive equipment and isolates pending edits/deletion" $ do
        (owner, borrower, eid, now) <- fixture
        let start = addUTCTime 3600 now
            end = addUTCTime 7200 now
        denied $ saveRequest owner eid Nothing start end "Own"
        forM_ [(now, end), (start, start), (end, start)] $ \(s, e) ->
            denied $ saveRequest borrower eid Nothing s e "Invalid period"
        rid <- runDB $ saveRequest borrower eid Nothing start end "Study"
        denied $ saveRequest owner eid (Just rid) start end "Forged"
        denied $ removeRequest owner rid
        _ <- runDB $ saveRequest borrower eid (Just rid) start end "Updated"
        updated <- runDB $ getJust rid
        liftIO $ loanRequestPurpose updated `shouldBe` "Updated"
        runDB $ removeRequest borrower rid
        runDB $ update eid [EquipmentActive =. False]
        denied $ saveRequest borrower eid Nothing start end "Inactive"

    it "reserves half-open periods, preserves cancellation and requires a refusal reason" $ do
        (owner, borrower, eid, now) <- fixture
        first <- makeRequest borrower eid now 3600 7200
        overlap <- makeRequest borrower eid now 5400 9000
        adjacent <- makeRequest borrower eid now 7200 10800
        runDB $ update owner [UserStreet =. Nothing]
        denied $ decideRequest owner first True ""
        setAddress owner
        runDB $ decideRequest owner first True ""
        denied $ decideRequest owner overlap True ""
        runDB $ decideRequest owner adjacent True ""
        denied $ removeRequest borrower first
        denied $ decideRequest owner overlap False " "
        runDB $ cancelRequest borrower first
        cancelled <- runDB $ getJust first
        liftIO $ loanRequestStatus cancelled `shouldBe` Cancelled
        runDB $ cancelRequest owner adjacent
        runDB $ decideRequest owner overlap False "Unavailable"
        rejected <- runDB $ getJust overlap
        liftIO $ loanRequestRejectionReason rejected `shouldBe` Just "Unavailable"
        denied $ cancelRequest borrower overlap

    it "allows only one of two concurrently overlapping approvals and serializes maintenance against approval" $ do
        (owner, borrower, eid, now) <- fixture
        first <- makeRequest borrower eid now 3600 7200
        second <- makeRequest borrower eid now 3600 7200
        pool <- appConnPool <$> getTestYesod
        let attempt action = E.try $ runSqlPersistMPool action pool
        (a, b) <- bounded $ concurrently
            (attempt $ decideRequest owner first True "")
            (attempt $ decideRequest owner second True "")
        liftIO $ length (rights [a, b] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [a, b] :: [LendingError]) `shouldBe` 1
        runDB $ do
            update first [LoanRequestStatus =. Pending]
            update second [LoanRequestStatus =. Pending]
        (approval, maintenance) <- bounded $ concurrently
            (attempt $ decideRequest owner first True "")
            (attempt $ void $ openMaintenance owner eid "Repair")
        liftIO $ length (rights [approval, maintenance] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [approval, maintenance] :: [LendingError]) `shouldBe` 1

    it "keeps maintenance history, blocks availability and requires a completion result" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- makeRequest borrower eid now 3600 7200
        mid <- runDB $ openMaintenance owner eid "Cable"
        denied $ openMaintenance owner eid "Second"
        denied $ changeMaintenance borrower mid False "Forged"
        denied $ decideRequest owner rid True ""
        denied $ changeMaintenance owner mid True " "
        runDB $ changeMaintenance owner mid False "New cable"
        runDB $ changeMaintenance owner mid True "Cable replaced"
        closed <- runDB $ getJust mid
        liftIO $ do
            maintenanceReason closed `shouldBe` "New cable"
            maintenanceResult closed `shouldBe` Just "Cable replaced"
            maintenanceFinishedAt closed `shouldSatisfy` isJust
        denied $ changeMaintenance owner mid False "Reopened"
        runDB $ decideRequest owner rid True ""
        denied $ openMaintenance owner eid "Approved reserve"
        denied $ removeEquipment owner eid

    it "allows only one concurrently opened maintenance for the same equipment" $ do
        (owner, _, eid, _) <- fixture
        pool <- appConnPool <$> getTestYesod
        let attempt = E.try $ runSqlPersistMPool (openMaintenance owner eid "Repair") pool
        (a, b) <- bounded $ concurrently attempt attempt
        liftIO $ length (rights [a, b] :: [MaintenanceId]) `shouldBe` 1
        liftIO $ length (lefts [a, b] :: [LendingError]) `shouldBe` 1
        total <- runDB $ count [MaintenanceEquipmentId ==. eid, MaintenanceFinishedAt ==. Nothing]
        liftIO $ total `shouldBe` 1

    it "atomically checks out with one initial inspection and blocks duplicate or unavailable checkout" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- makeRequest borrower eid now 3600 7200
        denied $ checkout owner rid Good ""
        runDB $ decideRequest owner rid True ""
        denied $ checkout owner rid Good ""
        runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
        denied $ checkout borrower rid Good ""
        denied $ checkout owner rid Damaged " "
        pool <- appConnPool <$> getTestYesod
        let attempt = E.try $ runSqlPersistMPool (checkout owner rid Good "Checked") pool
        (a, b) <- bounded $ concurrently attempt attempt
        liftIO $ length (rights [a, b] :: [LoanId]) `shouldBe` 1
        liftIO $ length (lefts [a, b] :: [LendingError]) `shouldBe` 1
        loan <- runDB $ getBy $ UniqueLoanRequest rid
        case loan of
            Nothing -> liftIO $ expectationFailure "Checkout must create a loan"
            Just (Entity lid value) -> do
                inspection <- runDB $ getBy $ UniqueLoanInspection lid CheckoutInspection
                source <- runDB $ getJust rid
                liftIO $ do
                    loanDueAt value `shouldBe` loanRequestEndsAt source
                    loanReturnedAt value `shouldBe` Nothing
                    inspection `shouldSatisfy` isJust
        denied $ openMaintenance owner eid "Open loan"
        other <- makeRequest borrower eid now 7200 10800
        denied $ decideRequest owner other True ""
        collected <- runDB $ getJust rid
        liftIO $ loanRequestStatus collected `shouldBe` Collected

    it "rolls back checkout completely if insertion of its inspection fails" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- makeRequest borrower eid now 3600 7200
        runDB $ decideRequest owner rid True ""
        runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
        -- A transactional trigger models a database failure between the two inserts.
        pool <- appConnPool <$> getTestYesod
        let transaction = do
                rawExecute "CREATE FUNCTION pg_temp.fail_inspection() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated inspection failure'; END $$" []
                rawExecute "CREATE TRIGGER test_fail_inspection BEFORE INSERT ON inspection FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_inspection()" []
                checkout owner rid Good ""
        result <- liftIO $ E.try $ runSqlPersistMPool transaction pool
        liftIO $ case result of
            Left err -> sqlState err `shouldBe` "P0001"
            Right _ -> expectationFailure "Expected simulated database failure"
        loan <- runDB $ getBy $ UniqueLoanRequest rid
        persisted <- runDB $ getJust rid
        liftIO $ do
            loan `shouldBe` Nothing
            loanRequestStatus persisted `shouldBe` Approved

    it "blocks checkout after the approved period and when participants become inactive" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- makeRequest borrower eid now 3600 7200
        runDB $ decideRequest owner rid True ""
        runDB $ update rid
            [LoanRequestStartsAt =. addUTCTime (-120) now, LoanRequestEndsAt =. addUTCTime (-60) now]
        denied $ checkout owner rid Good ""
        runDB $ update rid [LoanRequestEndsAt =. addUTCTime 3600 now]
        runDB $ update borrower [UserActive =. False]
        denied $ checkout owner rid Good ""
        runDB $ update borrower [UserActive =. True]
        mid <- runDB $ do
            update rid [LoanRequestStatus =. Cancelled]
            openMaintenance owner eid "Repair"
        runDB $ update rid [LoanRequestStatus =. Approved]
        denied $ checkout owner rid Good ""
        runDB $ changeMaintenance owner mid True "Done"

    it "returns normally with a final inspection, preserving history and releasing availability" $ do
        (owner, _, eid, lid) <- checkedOutFixture
        runDB $ returnLoan owner lid Worn "Normal wear"
        loan <- runDB $ getJust lid
        inspection <- runDB $ getBy $ UniqueLoanInspection lid ReturnInspection
        equipment <- runDB $ getJust eid
        free <- runDB $ availableNow eid equipment
        maintenance <- runDB $ count [MaintenanceEquipmentId ==. eid]
        liftIO $ do
            loanReturnedAt loan `shouldSatisfy` isJust
            equipmentCondition equipment `shouldBe` Worn
            free `shouldBe` True
            maintenance `shouldBe` 0
            case inspection of
                Just (Entity _ value) -> do
                    inspectionInspectorId value `shouldBe` owner
                    inspectionCondition value `shouldBe` Worn
                    Just (inspectionPerformedAt value) `shouldBe` loanReturnedAt loan
                Nothing -> expectationFailure "Missing final inspection"
        denied $ returnLoan owner lid Good ""

    it "requires owner and damage notes, atomically opens maintenance and only permits correction of notes" $ do
        (owner, borrower, eid, lid) <- checkedOutFixture
        denied $ returnLoan borrower lid Damaged "Broken cable"
        denied $ returnLoan owner lid Damaged " "
        runDB $ returnLoan owner lid Damaged "Broken cable"
        loan <- runDB $ getJust lid
        inspection <- requireRecord =<< (runDB $ getBy $ UniqueLoanInspection lid ReturnInspection)
        let Entity iid initial = inspection
        records <- runDB $ selectList [MaintenanceEquipmentId ==. eid] []
        case records of
            [Entity mid maintenance] -> do
                liftIO $ Just (maintenanceStartedAt maintenance) `shouldBe` loanReturnedAt loan
                equipment <- runDB $ getJust eid
                free <- runDB $ availableNow eid equipment
                liftIO $ free `shouldBe` False
                denied $ correctInspectionNotes borrower iid "Forged"
                denied $ correctInspectionNotes owner iid " "
                runDB $ correctInspectionNotes owner iid "Broken connector"
                updated <- runDB $ getJust iid
                liftIO $ updated `shouldBe` initial { inspectionNotes = "Broken connector" }
                runDB $ changeMaintenance owner mid True "Repaired"
            _ -> liftIO $ expectationFailure "Expected exactly one damage maintenance"

    it "rejects return before checkout and rolls back every write after inspection or maintenance failure" $ do
        (owner, _, eid, lid) <- checkedOutFixture
        loan <- runDB $ getJust lid
        now <- liftIO getCurrentTime
        runDB $ update lid [LoanCheckedOutAt =. addUTCTime 3600 now]
        denied $ returnLoan owner lid Good ""
        runDB $ update lid [LoanCheckedOutAt =. loanCheckedOutAt loan]
        pool <- appConnPool <$> getTestYesod
        forM_ ["inspection", "maintenance"] $ \table -> do
            let transaction = do
                    rawExecute "CREATE FUNCTION pg_temp.fail_return() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated return failure'; END $$" []
                    rawExecute ("CREATE TRIGGER test_fail_return BEFORE INSERT ON " <> table <>
                        " FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_return()") []
                    returnLoan owner lid Damaged "Broken"
            result <- liftIO $ E.try $ runSqlPersistMPool transaction pool
            liftIO $ case result of
                Left err -> sqlState err `shouldBe` "P0001"
                Right () -> expectationFailure "Expected return failure"
            persisted <- runDB $ getJust lid
            final <- runDB $ getBy $ UniqueLoanInspection lid ReturnInspection
            equipment <- runDB $ getJust eid
            maintenance <- runDB $ count [MaintenanceEquipmentId ==. eid]
            liftIO $ do
                loanReturnedAt persisted `shouldBe` Nothing
                final `shouldBe` Nothing
                equipmentCondition equipment `shouldBe` Good
                maintenance `shouldBe` 0

    it "serializes duplicate damaged returns into one final inspection and one maintenance" $ do
        (owner, _, eid, lid) <- checkedOutFixture
        pool <- appConnPool <$> getTestYesod
        let attempt = E.try $ runSqlPersistMPool (returnLoan owner lid Damaged "Broken") pool
        (a, b) <- bounded $ concurrently attempt attempt
        liftIO $ length (rights [a, b] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [a, b] :: [LendingError]) `shouldBe` 1
        final <- runDB $ count [InspectionLoanId ==. lid, InspectionKind ==. ReturnInspection]
        maintenance <- runDB $ count [MaintenanceEquipmentId ==. eid]
        liftIO $ (final, maintenance) `shouldBe` (1, 1)

    it "deletes only accounts without domain history and preserves linked accounts by deactivation" $ do
        Entity uid _ <- createUser "temporary"
        runDB $ removeAccount uid
        deleted <- runDB $ DB.get uid
        emails <- runDB $ count [EmailUserId ==. Just uid]
        liftIO $ do
            isNothing deleted `shouldBe` True
            emails `shouldBe` 0
        (owner, borrower, eid, now) <- fixture
        denied $ removeAccount owner
        rid <- makeRequest borrower eid now 3600 7200
        denied $ removeAccount borrower
        runDB $ deactivateAccount borrower borrower
        user <- runDB $ getJust borrower
        persisted <- runDB $ getJust rid
        liftIO $ do
            userActive user `shouldBe` False
            loanRequestStatus persisted `shouldBe` Pending
        denied $ decideRequest owner rid True ""

    it "blocks account and equipment deactivation through approval and checkout, then permits it after return" $ do
        (owner, borrower, eid, now) <- fixture
        Entity admin _ <- createUser "admin"
        runDB $ update admin [UserRole =. Administrator]
        denied $ deactivateAccount borrower owner
        denied $ deactivateEquipment borrower eid
        rid <- makeRequest borrower eid now 3600 7200
        runDB $ decideRequest owner rid True ""
        forM_ [owner, borrower] $ \uid -> denied $ deactivateAccount admin uid
        denied $ deactivateEquipment admin eid
        runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
        lid <- runDB $ checkout owner rid Good ""
        forM_ [owner, borrower] $ \uid -> denied $ deactivateAccount admin uid
        denied $ deactivateEquipment admin eid
        runDB $ returnLoan owner lid Good ""
        runDB $ deactivateEquipment admin eid
        runDB $ deactivateAccount admin borrower
        runDB $ deactivateAccount owner owner
        equipment <- runDB $ getJust eid
        liftIO $ equipmentActive equipment `shouldBe` False

    it "coordinates concurrent equipment or participant deactivation with reservation approval" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- makeRequest borrower eid now 3600 7200
        pool <- appConnPool <$> getTestYesod
        let attempt action = E.try $ runSqlPersistMPool action pool
        (approval, deactivation) <- bounded $ concurrently
            (attempt $ decideRequest owner rid True "")
            (attempt $ deactivateEquipment owner eid)
        liftIO $ length (rights [approval, deactivation] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [approval, deactivation] :: [LendingError]) `shouldBe` 1
        runDB $ update eid [EquipmentActive =. True]
        runDB $ update rid [LoanRequestStatus =. Pending]
        (approved, inactive) <- bounded $ concurrently
            (attempt $ decideRequest owner rid True "")
            (attempt $ deactivateAccount borrower borrower)
        liftIO $ length (rights [approved, inactive] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [approved, inactive] :: [LendingError]) `shouldBe` 1
        user <- runDB $ getJust borrower
        persisted <- runDB $ getJust rid
        liftIO $ (userActive user || loanRequestStatus persisted /= Approved) `shouldBe` True

    it "serializes account deletion against equipment publication without leaving orphan records" $ do
        Entity uid _ <- createUser "owner"
        setAddress uid
        cid <- runDB $ insert $ Category "Tools" "Tools"
        pool <- appConnPool <$> getTestYesod
        let attempt action = E.try $ runSqlPersistMPool action pool
        (removed, published) <- bounded $ concurrently
            (attempt $ removeAccount uid)
            (attempt $ void $ saveEquipment uid Nothing "Kit" "Kit" "KIT" Good cid)
        liftIO $ length (rights [removed, published] :: [()]) `shouldBe` 1
        liftIO $ length (lefts [removed, published] :: [LendingError]) `shouldBe` 1
        user <- runDB $ DB.get uid
        equipment <- runDB $ count [EquipmentOwnerId ==. uid]
        liftIO $ case user of
            Nothing -> equipment `shouldBe` 0
            Just _ -> equipment `shouldBe` 1

denied :: SqlPersistM a -> YesodExample App ()
denied action = do
    pool <- appConnPool <$> getTestYesod
    result <- liftIO $ E.try $ runSqlPersistMPool (void action) pool
    liftIO $ case result of
        Left (LendingError message) -> T.null message `shouldBe` False
        Right () -> expectationFailure "Expected an explicit domain error"

bounded :: IO a -> YesodExample App a
bounded action = do
    result <- liftIO $ Timeout.timeout 10000000 action
    maybe (error "Concurrent operation exceeded 10 seconds") pure result

requireRecord :: Maybe a -> YesodExample App a
requireRecord = maybe (error "Expected a persisted record") pure

checkedOutFixture :: YesodExample App (UserId, UserId, EquipmentId, LoanId)
checkedOutFixture = do
    (owner, borrower, eid, now) <- fixture
    rid <- makeRequest borrower eid now 3600 7200
    runDB $ decideRequest owner rid True ""
    runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
    lid <- runDB $ checkout owner rid Good "Initial inspection"
    pure (owner, borrower, eid, lid)

setAddress :: UserId -> YesodExample App ()
setAddress uid = runDB $ update uid
    [UserPostalCode =. Just "01310100", UserStreet =. Just "Avenida Publica",
     UserNeighborhood =. Just "Centro", UserCity =. Just "Sao Paulo",
     UserState =. Just "SP", UserAddressNumber =. Just "100"]

fixture :: YesodExample App (UserId, UserId, EquipmentId, UTCTime)
fixture = do
    Entity owner _ <- createUser "owner"
    Entity borrower _ <- createUser "borrower"
    setAddress owner
    now <- liftIO getCurrentTime
    eid <- runDB $ do
        cid <- insert $ Category "Tools" "Lab tools"
        saveEquipment owner Nothing "Arduino" "Starter kit" "KIT-1" Good cid
    pure (owner, borrower, eid, now)

makeRequest :: UserId -> EquipmentId -> UTCTime -> NominalDiffTime -> NominalDiffTime -> YesodExample App LoanRequestId
makeRequest borrower eid now start end =
    runDB $ saveRequest borrower eid Nothing (addUTCTime start now) (addUTCTime end now) "Study"

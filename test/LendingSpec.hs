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

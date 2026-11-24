{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.LendingSpec (spec) where

import TestImport
import qualified Lending as L
import Handler.LendingCommon (timestampInput)
import Data.Time (addUTCTime)
import Database.Persist.Sql (toSqlKey, fromSqlKey)
import qualified Database.Persist as DB
import Yesod.Core (renderRoute)
import qualified Data.Text as T

spec :: Spec
spec = withApp $ describe "Lending pages" $ do
    it "supports category and equipment CRUD through forms, rejecting CSRF and third-party mutations" $ do
        admin@(Entity adminId _) <- createUser "admin"
        owner@(Entity ownerId _) <- createUser "owner"
        runDB $ update adminId [UserRole =. Administrator]
        authenticateAs owner
        get CategoriesR
        statusIs 403
        authenticateAs admin
        get CategoriesR
        postFields CategoriesR [("name", "Tools"), ("description", "Lab tools")]
        statusIs 303
        Entity cid _ <- requireFound =<< (runDB $ getBy $ UniqueCategoryName "Tools")
        get $ CategoryEditR cid
        postFields (CategoryEditR cid) [("name", "Electronics"), ("description", "Kits")]
        statusIs 303
        authenticateAs owner
        get EquipmentNewR
        postFields EquipmentNewR equipmentFields
        statusIs 409
        setAddress ownerId
        get EquipmentNewR
        request $ do
            setMethod "POST"
            setUrl EquipmentNewR
            mapM_ (uncurry addPostParam) equipmentFields
        total <- runDB $ count ([] :: [Filter Equipment])
        liftIO $ total `shouldBe` 0
        get EquipmentNewR
        postFields EquipmentNewR equipmentFields
        statusIs 303
        Entity eid _ <- requireFound =<< (runDB $ getBy $ UniqueEquipmentIdentification ownerId "KIT-1")
        get $ EquipmentEditR eid
        postFields (EquipmentEditR eid) $
            ("name", "Updated kit") : filter ((/= "name") . fst) equipmentFields
        statusIs 303
        get $ EquipmentR eid
        htmlAnyContain "h1" "Updated kit"
        authenticateAs admin
        get $ EquipmentEditR eid
        statusIs 403
        get CategoriesR
        postFields (CategoryDeleteR cid) []
        statusIs 409
        authenticateAs owner
        get $ EquipmentR eid
        postFields (EquipmentDeleteR eid) []
        statusIs 303
        authenticateAs admin
        get CategoriesR
        postFields (CategoryDeleteR cid) []
        statusIs 303

    it "provides deterministic catalog pagination and literal name/category filters without leaking addresses" $ do
        owner@(Entity uid _) <- createUser "owner"
        setAddress uid
        now <- liftIO getCurrentTime
        cid <- runDB $ insert $ Category "Tools" "Tools"
        runDB $ forM_ [1..22 :: Int] $ \n -> insert_ $
            Equipment "Same" "Kit" (tshow n) Good True uid cid now
        _ <- runDB $ insert $ Equipment "100% kit" "Literal" "percent" Good True uid cid now
        authenticateAs owner
        get CatalogR
        htmlCount "section.panel" 20
        htmlAnyContain "a" "Proxima"
        request $ do
            setUrl CatalogR
            addGetParam "page" "2"
        htmlCount "section.panel" 3
        request $ do
            setUrl CatalogR
            addGetParam "name" "%"
            addGetParam "category" $ tshow $ fromSqlKey cid
        htmlCount "section.panel" 1
        bodyNotContains "Avenida Publica"
        get $ EquipmentR $ toSqlKey (-1)
        statusIs 404

    it "keeps pickup addresses private until approval, locks address changes and preserves cancelled requests" $ do
        (owner, borrower, eid, now) <- fixture
        rid <- runDB $ L.saveRequest (entityKey borrower) eid Nothing
            (addUTCTime 3600 now) (addUTCTime 7200 now) "Study"
        outsider <- createUser "outsider"
        authenticateAs outsider
        get $ RequestR rid
        statusIs 403
        authenticateAs borrower
        get $ RequestR rid
        htmlCount "#pickup-address" 0
        bodyNotContains "Avenida Publica"
        authenticateAs owner
        get $ RequestR rid
        postFields (RequestApproveR rid) []
        statusIs 303
        get ProfileR
        postFields ProfileR [("name", "Owner"), ("street", "Changed")]
        statusIs 409
        saved <- runDB $ getJust $ entityKey owner
        liftIO $ userStreet saved `shouldBe` Just "Avenida Publica"
        authenticateAs borrower
        get $ RequestR rid
        htmlAnyContain "#pickup-address" "Avenida Publica"
        postFields (RequestCancelR rid) []
        statusIs 303
        get $ RequestR rid
        htmlCount "#pickup-address" 0
        bodyNotContains "Avenida Publica"
        authenticateAs owner
        get ProfileR
        postFields ProfileR [("name", "Owner")]
        statusIs 303

    it "creates a pending request from local time, edits and deletes it only for its requester" $ do
        (_, borrower, eid, now) <- fixture
        authenticateAs borrower
        get $ RequestNewR eid
        let fields = [("startsAt", timestampInput $ addUTCTime 3600 now),
                ("endsAt", timestampInput $ addUTCTime 7200 now), ("purpose", "Study")]
        postFields (RequestNewR eid) fields
        statusIs 303
        Entity rid _ <- requireSingle =<< (runDB $ selectList [LoanRequestEquipmentId ==. eid] [])
        get $ RequestEditR rid
        postFields (RequestEditR rid) $ ("purpose", "Updated") : filter ((/= "purpose") . fst) fields
        statusIs 303
        get $ RequestR rid
        htmlAnyContain "p" "Updated"
        postFields (RequestDeleteR rid) []
        statusIs 303
        saved <- runDB $ DB.get rid
        liftIO $ saved `shouldBe` Nothing

    it "opens and completes maintenance through the UI and displays an atomic checkout to participants" $ do
        (owner, borrower, eid, now) <- fixture
        authenticateAs owner
        get $ EquipmentMaintenanceR eid
        postFields (EquipmentMaintenanceR eid) [("value", "Repair")]
        statusIs 303
        Entity mid _ <- requireSingle =<< (runDB $ selectList [MaintenanceEquipmentId ==. eid] [])
        get $ MaintenanceR mid
        postFields (MaintenanceEditR mid) [("value", "Replace cable")]
        statusIs 303
        get $ MaintenanceR mid
        postFields (MaintenanceFinishR mid) [("value", "Cable replaced")]
        statusIs 303
        rid <- runDB $ L.saveRequest (entityKey borrower) eid Nothing
            (addUTCTime 3600 now) (addUTCTime 7200 now) "Study"
        runDB $ L.decideRequest (entityKey owner) rid True ""
        runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
        get $ CheckoutR rid
        postFields (CheckoutR rid) [("condition", "1"), ("notes", "Checked")]
        statusIs 303
        Entity lid _ <- requireFound =<< (runDB $ getBy $ UniqueLoanRequest rid)
        get $ LoanR lid
        htmlAnyContain "h3" "Retirada"
        authenticateAs borrower
        get LoansR
        htmlAnyContain "h2" "Arduino"
        get $ LoanR lid
        statusIs 200
        authenticateAs owner
        get ProfileR
        postFields ProfileR [("name", "Owner"), ("street", "Changed")]
        statusIs 409
        get $ CheckoutR rid
        postFields (CheckoutR rid) [("condition", "1"), ("notes", "Duplicate")]
        statusIs 409

    it "rejects malformed ViaCEP input locally without overwriting saved profile data" $ do
        owner@(Entity uid _) <- createUser "owner"
        setAddress uid
        authenticateAs owner
        get ProfileR
        postFields ProfileCEPR [("cep", "bad/input")]
        statusIs 200
        htmlAnyContain "#message" "oito digitos"
        saved <- runDB $ getJust uid
        liftIO $ userStreet saved `shouldBe` Just "Avenida Publica"

    it "shows overdue loans and confirms owner-only return with damage maintenance and immutable inspection metadata" $ do
        (owner, borrower, eid, lid) <- loanFixture
        now <- liftIO getCurrentTime
        runDB $ update lid [LoanDueAt =. addUTCTime (-60) now]
        authenticateAs borrower
        get LoansR
        htmlAnyContain "p" "atrasado"
        get $ ReturnLoanR lid
        statusIs 403
        authenticateAs owner
        get $ ReturnLoanR lid
        htmlCount "form[onsubmit]" 1
        request $ do
            setMethod "POST"
            setUrl $ ReturnLoanR lid
            addPostParam "condition" "3"
            addPostParam "notes" "Broken"
        unchanged <- runDB $ getJust lid
        liftIO $ loanReturnedAt unchanged `shouldBe` Nothing
        get $ ReturnLoanR lid
        postFields (ReturnLoanR lid) [("condition", "3"), ("notes", "")]
        statusIs 409
        get $ ReturnLoanR lid
        postFields (ReturnLoanR lid) [("condition", "3"), ("notes", "Broken cable")]
        statusIs 303
        get $ LoanR lid
        htmlAnyContain "h3" "Devolucao"
        htmlAnyContain "p" "Encerrado"
        Entity iid initial <- requireFound =<< (runDB $ getBy $ UniqueLoanInspection lid ReturnInspection)
        get $ InspectionEditR iid
        postFields (InspectionEditR iid)
            [("notes", "Broken connector"), ("condition", "1"), ("kind", "CheckoutInspection"),
             ("inspectorId", tshow $ fromSqlKey $ entityKey borrower), ("performedAt", "2000-01-01")]
        statusIs 303
        persisted <- runDB $ getJust iid
        liftIO $ persisted `shouldBe` initial { inspectionNotes = "Broken connector" }
        get $ EquipmentMaintenanceR eid
        htmlAnyContain "a" "Dano na devolucao"
        authenticateAs borrower
        get $ InspectionEditR iid
        statusIs 403

    it "excludes accounts without links, clears sessions and only deactivates accounts with history" $ do
        temporary@(Entity uid _) <- createUser "temporary"
        authenticateAs temporary
        get ProfileR
        request $ do
            setMethod "POST"
            setUrl ProfileDeleteR
        persisted <- runDB $ DB.get uid
        liftIO $ isJust persisted `shouldBe` True
        get ProfileR
        postFields ProfileDeleteR []
        statusIs 303
        removed <- runDB $ DB.get uid
        liftIO $ isNothing removed `shouldBe` True
        get ProfileR
        statusIs 403
        (owner, _, _, _) <- fixture
        authenticateAs owner
        get ProfileR
        postFields ProfileDeleteR []
        statusIs 409
        get ProfileR
        postFields ProfileDeactivateR []
        statusIs 303
        inactive <- runDB $ getJust $ entityKey owner
        liftIO $ userActive inactive `shouldBe` False
        get ProfileR
        statusIs 403

    it "permits admin support and deactivation without bypassing owner mutations or existing sessions" $ do
        (owner, borrower, eid, lid) <- loanFixture
        admin@(Entity adminId _) <- createUser "admin"
        runDB $ update adminId [UserRole =. Administrator]
        authenticateAs borrower
        get AdminR
        statusIs 403
        authenticateAs admin
        forM_ [AdminR, AdminUsersR, AdminEquipmentR, AdminRequestsR, AdminLoansR,
                AdminUserR (entityKey owner), LoanR lid] $ \route -> get route >> statusIs 200
        get $ AdminUserR $ entityKey borrower
        postFields (AdminUserDeactivateR $ entityKey borrower) []
        statusIs 409
        get $ EquipmentR eid
        postFields (EquipmentDeactivateR eid) []
        statusIs 409
        get $ ReturnLoanR lid
        statusIs 403
        runDB $ L.returnLoan (entityKey owner) lid Damaged "Broken cable"
        Entity mid _ <- requireSingle =<< (runDB $ selectList [MaintenanceEquipmentId ==. eid] [])
        get $ EquipmentMaintenanceR eid
        statusIs 200
        get $ MaintenanceR mid
        statusIs 200
        htmlCount "form" 0
        request $ do
            setMethod "POST"
            setUrl $ MaintenanceFinishR mid
            addPostParam "value" "Forged"
        statusIs 403
        get $ EquipmentR eid
        postFields (EquipmentDeactivateR eid) []
        statusIs 303
        get AdminEquipmentR
        htmlAnyContain "h2" "Arduino"
        authenticateAs borrower
        get ProfileR
        runDB $ L.deactivateAccount adminId $ entityKey borrower
        get ProfileR
        statusIs 403

    it "keeps action forms and unrelated content outside navigation links" $ do
        (owner, _, eid, lid) <- loanFixture
        authenticateAs owner
        forM_ [CatalogR, EquipmentR eid, LoanR lid] $ \route -> do
            get route
            statusIs 200
            htmlCount "a form" 0
            htmlCount "a footer" 0

    it "hides deactivated equipment from catalog but preserves authorized history and rejects new operations" $ do
        (owner, borrower, eid, _) <- fixture
        authenticateAs owner
        get $ EquipmentR eid
        postFields (EquipmentDeactivateR eid) []
        statusIs 303
        get MyEquipmentR
        htmlAnyContain "h2" "Arduino"
        authenticateAs borrower
        get CatalogR
        htmlCount "section.panel" 0
        get $ EquipmentR eid
        statusIs 403
        get $ RequestNewR eid
        now <- liftIO getCurrentTime
        postFields (RequestNewR eid)
            [("startsAt", timestampInput $ addUTCTime 3600 now),
             ("endsAt", timestampInput $ addUTCTime 7200 now), ("purpose", "Study")]
        statusIs 409

postFields :: Route App -> [(Text, Text)] -> YesodExample App ()
postFields route fields = request $ do
    setMethod "POST"
    setUrl route
    addToken_ $ "form[action$=/" <> T.intercalate "/" (fst $ renderRoute route) <> "]"
    mapM_ (uncurry addPostParam) fields

requireFound :: Maybe a -> YesodExample App a
requireFound = maybe (error "Expected a persisted record") pure

requireSingle :: [a] -> YesodExample App a
requireSingle [value] = pure value
requireSingle _ = error "Expected exactly one persisted record"

equipmentFields :: [(Text, Text)]
equipmentFields = [("name", "Arduino"), ("description", "Starter kit"),
    ("identification", "KIT-1"), ("condition", "1"), ("category", "1")]

setAddress :: UserId -> YesodExample App ()
setAddress uid = runDB $ update uid
    [UserPostalCode =. Just "01310100", UserStreet =. Just "Avenida Publica",
     UserNeighborhood =. Just "Centro", UserCity =. Just "Sao Paulo",
     UserState =. Just "SP", UserAddressNumber =. Just "100"]

fixture :: YesodExample App (Entity User, Entity User, EquipmentId, UTCTime)
fixture = do
    owner <- createUser "owner"
    borrower <- createUser "borrower"
    setAddress $ entityKey owner
    now <- liftIO getCurrentTime
    eid <- runDB $ do
        cid <- insert $ Category "Tools" "Lab tools"
        L.saveEquipment (entityKey owner) Nothing "Arduino" "Starter kit" "KIT-1" Good cid
    pure (owner, borrower, eid, now)

loanFixture :: YesodExample App (Entity User, Entity User, EquipmentId, LoanId)
loanFixture = do
    (owner, borrower, eid, now) <- fixture
    rid <- runDB $ L.saveRequest (entityKey borrower) eid Nothing
        (addUTCTime 3600 now) (addUTCTime 7200 now) "Study"
    runDB $ L.decideRequest (entityKey owner) rid True ""
    runDB $ update rid [LoanRequestStartsAt =. addUTCTime (-60) now]
    lid <- runDB $ L.checkout (entityKey owner) rid Good ""
    pure (owner, borrower, eid, lid)

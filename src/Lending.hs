{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
module Lending where

import ClassyPrelude.Yesod
import Database.Persist.Sql (rawSql, Single (..))
import qualified Data.Text as T
import qualified Data.List as List
import qualified Control.Exception as E

import Model

newtype LendingError = LendingError Text deriving (Show, Typeable)
instance E.Exception LendingError

ensure :: MonadIO m => Bool -> Text -> m ()
ensure ok message = unless ok $ liftIO $ E.throwIO $ LendingError message

nonBlank :: MonadIO m => Text -> m ()
nonBlank value = ensure (not $ T.null $ T.strip value) "Preencha os campos obrigatorios."

getRequired :: (MonadIO m, PersistEntity record, PersistEntityBackend record ~ SqlBackend)
    => Key record -> SqlPersistT m record
getRequired key = do
    found <- get key
    maybe (liftIO $ E.throwIO $ LendingError "Registro nao encontrado ou removido por outra operacao.") pure found

-- Lock participants in a stable order before equipment; profile edits use the
-- same user lock, so approval cannot race an address change.
lockUsers :: MonadIO m => [UserId] -> SqlPersistT m ()
lockUsers ids = forM_ (List.nub $ List.sort ids) $ \uid -> do
    rows <- rawSql "SELECT ?? FROM \"user\" WHERE id = ? FOR UPDATE" [toPersistValue uid]
    ensure (not $ null (rows :: [Entity User])) "Usuario nao encontrado."

activeUser :: MonadIO m => UserId -> SqlPersistT m User
activeUser uid = do
    user <- getRequired uid
    ensure (userActive user) "Conta inativa."
    pure user

lockedEquipment :: MonadIO m => UserId -> EquipmentId -> SqlPersistT m Equipment
lockedEquipment actor eid = do
    found <- get eid
    initial <- maybe (liftIO $ E.throwIO $ LendingError "Equipamento nao encontrado.") pure found
    lockUsers [actor, equipmentOwnerId initial]
    rows <- rawSql "SELECT ?? FROM equipment WHERE id = ? FOR UPDATE" [toPersistValue eid]
    equipment <- case rows of
        [Entity _ value] -> pure value
        _ -> liftIO $ E.throwIO $ LendingError "Equipamento nao encontrado."
    _ <- activeUser actor
    pure equipment

ownedEquipment :: MonadIO m => UserId -> EquipmentId -> SqlPersistT m Equipment
ownedEquipment actor eid = do
    equipment <- lockedEquipment actor eid
    ensure (equipmentOwnerId equipment == actor) "Acesso exclusivo do proprietario."
    pure equipment

completeAddress :: User -> Bool
completeAddress user = all (maybe False (not . T.null . T.strip))
    [ userPostalCode user, userStreet user, userNeighborhood user
    , userCity user, userState user, userAddressNumber user
    ]

hasOpenLoan :: MonadIO m => EquipmentId -> SqlPersistT m Bool
hasOpenLoan eid = do
    ids <- selectKeysList [LoanRequestEquipmentId ==. eid] []
    exists [LoanSourceRequestId <-. ids, LoanReturnedAt ==. Nothing]

hasMaintenance :: MonadIO m => EquipmentId -> SqlPersistT m Bool
hasMaintenance eid = exists [MaintenanceEquipmentId ==. eid, MaintenanceFinishedAt ==. Nothing]

availableNow :: MonadIO m => EquipmentId -> Equipment -> SqlPersistT m Bool
availableNow eid equipment = do
    loan <- hasOpenLoan eid
    maintenance <- hasMaintenance eid
    owner <- getRequired $ equipmentOwnerId equipment
    pure $ equipmentActive equipment && userActive owner && not loan && not maintenance

addressCommitted :: MonadIO m => UserId -> SqlPersistT m Bool
addressCommitted uid = do
    equipmentIds <- selectKeysList [EquipmentOwnerId ==. uid] []
    approved <- exists [LoanRequestEquipmentId <-. equipmentIds, LoanRequestStatus ==. Approved]
    loans <- or <$> mapM hasOpenLoan equipmentIds
    pure $ approved || loans

requireCategory :: MonadIO m => CategoryId -> SqlPersistT m ()
requireCategory cid = do
    rows <- rawSql "SELECT ?? FROM category WHERE id = ? FOR UPDATE" [toPersistValue cid]
    ensure (not $ null (rows :: [Entity Category])) "Categoria nao encontrada."

saveCategory :: MonadIO m => UserId -> Maybe CategoryId -> Text -> Text -> SqlPersistT m CategoryId
saveCategory actor current name description = do
    lockUsers [actor]
    user <- activeUser actor
    ensure (userRole user == Administrator) "Acesso exclusivo de administrador."
    nonBlank name
    nonBlank description
    _ <- (rawSql "SELECT 1 FROM pg_advisory_xact_lock(740901)" [] :: MonadIO m => SqlPersistT m [Single Int])
    duplicate <- getBy $ UniqueCategoryName $ T.strip name
    ensure (maybe True (\(Entity key _) -> Just key == current) duplicate) "Categoria ja cadastrada."
    let category = Category (T.strip name) (T.strip description)
    case current of
        Nothing -> insert category
        Just cid -> requireCategory cid >> replace cid category >> pure cid

removeCategory :: MonadIO m => UserId -> CategoryId -> SqlPersistT m ()
removeCategory actor cid = do
    lockUsers [actor]
    user <- activeUser actor
    ensure (userRole user == Administrator) "Acesso exclusivo de administrador."
    requireCategory cid
    used <- exists [EquipmentCategoryId ==. cid]
    ensure (not used) "Categoria usada por equipamentos; exclusao bloqueada."
    delete cid

saveEquipment :: MonadIO m
    => UserId -> Maybe EquipmentId -> Text -> Text -> Text
    -> EquipmentCondition -> CategoryId -> SqlPersistT m EquipmentId
saveEquipment actor current name description identification condition cid = do
    existing <- traverse (ownedEquipment actor) current
    lockUsers [actor]
    owner <- activeUser actor
    ensure (completeAddress owner) "Complete o endereco de retirada no perfil antes de publicar."
    mapM_ nonBlank [name, description, identification]
    requireCategory cid
    duplicate <- getBy $ UniqueEquipmentIdentification actor $ T.strip identification
    ensure (maybe True (\(Entity key _) -> Just key == current) duplicate)
        "Identificacao ja usada por outro equipamento seu."
    now <- liftIO getCurrentTime
    let equipment = Equipment (T.strip name) (T.strip description) (T.strip identification)
            condition (maybe True equipmentActive existing) actor cid
            (maybe now equipmentCreatedAt existing)
    case current of
        Nothing -> insert equipment
        Just eid -> replace eid equipment >> pure eid

removeEquipment :: MonadIO m => UserId -> EquipmentId -> SqlPersistT m ()
removeEquipment actor eid = do
    _ <- ownedEquipment actor eid
    requests <- exists [LoanRequestEquipmentId ==. eid]
    maintenance <- exists [MaintenanceEquipmentId ==. eid]
    ensure (not requests && not maintenance) "Equipamento com historico; exclusao bloqueada."
    delete eid

validatePeriod :: MonadIO m => UTCTime -> UTCTime -> SqlPersistT m ()
validatePeriod start end = do
    now <- liftIO getCurrentTime
    ensure (start > now && end > start) "Inicio deve estar no futuro e fim deve ser posterior ao inicio."

saveRequest :: MonadIO m
    => UserId -> EquipmentId -> Maybe LoanRequestId -> UTCTime -> UTCTime -> Text
    -> SqlPersistT m LoanRequestId
saveRequest actor eid current start end purpose = do
    equipment <- lockedEquipment actor eid
    _ <- activeUser $ equipmentOwnerId equipment
    ensure (actor /= equipmentOwnerId equipment) "Nao e permitido solicitar equipamento proprio."
    ensure (equipmentActive equipment) "Equipamento inativo."
    validatePeriod start end
    nonBlank purpose
    existing <- traverse getRequired current
    forM_ existing $ \request -> do
        ensure (loanRequestRequesterId request == actor && loanRequestEquipmentId request == eid)
            "Solicitacao de outro usuario."
        ensure (loanRequestStatus request == Pending) "Somente solicitacoes pendentes podem ser editadas."
    now <- liftIO getCurrentTime
    let request = LoanRequest eid actor start end (T.strip purpose) Pending Nothing
            (maybe now loanRequestCreatedAt existing)
    case current of
        Nothing -> insert request
        Just rid -> replace rid request >> pure rid

-- Request identity and equipment are immutable through the public workflow.
lockRequest :: MonadIO m => UserId -> LoanRequestId -> SqlPersistT m (LoanRequest, Equipment)
lockRequest actor rid = do
    request <- getRequired rid
    equipment <- getRequired $ loanRequestEquipmentId request
    lockUsers [actor, equipmentOwnerId equipment, loanRequestRequesterId request]
    locked <- lockedEquipment actor $ loanRequestEquipmentId request
    fresh <- getRequired rid
    pure (fresh, locked)

removeRequest :: MonadIO m => UserId -> LoanRequestId -> SqlPersistT m ()
removeRequest actor rid = do
    (request, _) <- lockRequest actor rid
    ensure (loanRequestRequesterId request == actor && loanRequestStatus request == Pending)
        "Somente o solicitante pode excluir uma solicitacao pendente."
    delete rid

cancelRequest :: MonadIO m => UserId -> LoanRequestId -> SqlPersistT m ()
cancelRequest actor rid = do
    (request, equipment) <- lockRequest actor rid
    ensure (actor == loanRequestRequesterId request || actor == equipmentOwnerId equipment)
        "Acesso exclusivo dos participantes."
    ensure (loanRequestStatus request `elem` [Pending, Approved]) "Solicitacao nao pode ser cancelada neste estado."
    update rid [LoanRequestStatus =. Cancelled]

decideRequest :: MonadIO m => UserId -> LoanRequestId -> Bool -> Text -> SqlPersistT m ()
decideRequest actor rid approve reason = do
    (request, equipment) <- lockRequest actor rid
    ensure (equipmentOwnerId equipment == actor) "Somente o proprietario pode decidir."
    ensure (loanRequestStatus request == Pending) "Somente solicitacoes pendentes podem ser decididas."
    if approve then do
        _ <- activeUser $ loanRequestRequesterId request
        owner <- activeUser $ equipmentOwnerId equipment
        ensure (completeAddress owner) "Proprietario precisa completar o endereco antes da aprovacao."
        validatePeriod (loanRequestStartsAt request) (loanRequestEndsAt request)
        free <- availableNow (loanRequestEquipmentId request) equipment
        ensure free "Equipamento indisponivel: inativo, emprestado ou em manutencao."
        overlap <- exists
            [ LoanRequestEquipmentId ==. loanRequestEquipmentId request
            , LoanRequestStatus ==. Approved
            , LoanRequestStartsAt <. loanRequestEndsAt request
            , LoanRequestEndsAt >. loanRequestStartsAt request
            ]
        ensure (not overlap) "Existe uma reserva aprovada para este periodo."
        update rid [LoanRequestStatus =. Approved, LoanRequestRejectionReason =. Nothing]
    else do
        nonBlank reason
        update rid [LoanRequestStatus =. Rejected, LoanRequestRejectionReason =. Just (T.strip reason)]

openMaintenance :: MonadIO m => UserId -> EquipmentId -> Text -> SqlPersistT m MaintenanceId
openMaintenance actor eid reason = do
    _ <- ownedEquipment actor eid
    nonBlank reason
    loan <- hasOpenLoan eid
    maintenance <- hasMaintenance eid
    approved <- exists [LoanRequestEquipmentId ==. eid, LoanRequestStatus ==. Approved]
    ensure (not loan && not maintenance && not approved)
        "Cancele reservas primeiro; emprestimo ou manutencao aberta tambem bloqueiam a abertura."
    now <- liftIO getCurrentTime
    insert $ Maintenance eid (T.strip reason) now Nothing Nothing

changeMaintenance :: MonadIO m => UserId -> MaintenanceId -> Bool -> Text -> SqlPersistT m ()
changeMaintenance actor mid finish value = do
    initial <- getRequired mid
    _ <- ownedEquipment actor $ maintenanceEquipmentId initial
    maintenance <- getRequired mid
    ensure (isNothing $ maintenanceFinishedAt maintenance) "Manutencao ja encerrada."
    nonBlank value
    if finish then do
        now <- liftIO getCurrentTime
        update mid [MaintenanceFinishedAt =. Just now, MaintenanceResult =. Just (T.strip value)]
    else update mid [MaintenanceReason =. T.strip value]

checkout :: MonadIO m => UserId -> LoanRequestId -> EquipmentCondition -> Text -> SqlPersistT m LoanId
checkout actor rid condition notes = do
    (request, equipment) <- lockRequest actor rid
    ensure (equipmentOwnerId equipment == actor) "Somente o proprietario pode registrar a retirada."
    _ <- activeUser $ loanRequestRequesterId request
    ensure (loanRequestStatus request == Approved) "Retirada exige solicitacao aprovada ainda nao retirada."
    now <- liftIO getCurrentTime
    ensure (now >= loanRequestStartsAt request && now < loanRequestEndsAt request)
        "Retirada permitida somente dentro do periodo aprovado."
    free <- availableNow (loanRequestEquipmentId request) equipment
    ensure free "Equipamento indisponivel para retirada."
    ensure (condition /= Damaged || not (T.null $ T.strip notes)) "Dano exige observacoes."
    lid <- insert $ Loan rid now (loanRequestEndsAt request) Nothing
    insert_ $ Inspection lid actor CheckoutInspection condition (T.strip notes) now
    update rid [LoanRequestStatus =. Collected]
    pure lid

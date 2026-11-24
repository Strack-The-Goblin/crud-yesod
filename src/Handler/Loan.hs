{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Loan where

import Import
import Lending
import Handler.LendingCommon

inspectionForm :: Form (EquipmentCondition, Text)
inspectionForm = conditionNotesForm "Condicao na retirada *"

conditionNotesForm :: Text -> Form (EquipmentCondition, Text)
conditionNotesForm label = renderDivs $ (,)
    <$> areq conditionField (textSettings label "condition") Nothing
    <*> (fromMaybe "" <$> aopt (requiredText 4000) (textSettings "Observacoes (obrigatorias em caso de dano)" "notes") Nothing)

checkoutOwner :: LoanRequestId -> Handler UserId
checkoutOwner rid = do
    (Entity uid _, _, equipment) <- requireRequestParticipant rid
    unless (equipmentOwnerId equipment == uid) $ permissionDenied "Somente o proprietario pode registrar a retirada."
    pure uid

getCheckoutR :: LoanRequestId -> Handler Html
getCheckoutR rid = do
    _ <- checkoutOwner rid
    (widget, enctype) <- generateFormPost inspectionForm
    editPage "Confirmar retirada e inspecao inicial" (CheckoutR rid) widget enctype

postCheckoutR :: LoanRequestId -> Handler Html
postCheckoutR rid = do
    uid <- checkoutOwner rid
    submitForm "Confirmar retirada e inspecao inicial" (CheckoutR rid) inspectionForm $ \(condition, notes) -> do
        lid <- checkout uid rid condition notes
        pure $ LoanR lid

getLoansR :: Handler Html
getLoansR = loanList False

getAdminLoansR :: Handler Html
getAdminLoansR = loanList True

loanList :: Bool -> Handler Html
loanList support = do
    Entity uid _ <- if support then requireAdministrator else requireActiveUser
    page <- getPage
    equipmentIds <- runDB $ selectKeysList [EquipmentOwnerId ==. uid] []
    requests <- runDB $ selectList
        ([LoanRequestRequesterId ==. uid] ||. [LoanRequestEquipmentId <-. equipmentIds]) []
    loans <- runDB $ selectList (if support then [] else [LoanSourceRequestId <-. map entityKey requests])
        [Desc LoanCheckedOutAt, Desc LoanId, LimitTo 21, OffsetBy ((page - 1) * 20)]
    rows <- forM (take 20 loans) $ \(Entity lid loan) -> do
        request <- runDB $ getJust $ loanSourceRequestId loan
        equipment <- runDB $ getJust $ loanRequestEquipmentId request
        pure (lid, loan, equipment)
    now <- liftIO getCurrentTime
    let heading = if support then ("Emprestimos (suporte)" :: Text) else "Meus emprestimos"
        route = if support then AdminLoansR else LoansR
    defaultLayout $ do
        setTitle "Meus emprestimos"
        [whamlet|
            <h1>#{heading}
            $if null rows
                <p>Nenhum emprestimo.
            $forall (lid, loan, equipment) <- rows
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2>
                            <a href=@{LoanR lid}>#{equipmentName equipment}
                        <p>Prazo: #{displayTime $ loanDueAt loan}
                        <p>#{loanSituation now loan}
            ^{pageNavigation route page (length loans > 20)}
        |]

loanSituation :: UTCTime -> Loan -> Text
loanSituation now loan
    | isJust (loanReturnedAt loan) = "Encerrado"
    | loanDueAt loan < now = "Aberto - atrasado"
    | otherwise = "Aberto"

getLoanR :: LoanId -> Handler Html
getLoanR lid = do
    _ <- requireActiveUser
    loan <- runDB $ get404 lid
    (Entity uid _, request, equipment) <- requireRequestParticipant $ loanSourceRequestId loan
    owner <- runDB $ getJust $ equipmentOwnerId equipment
    borrower <- runDB $ getJust $ loanRequestRequesterId request
    inspections <- runDB $ selectList [InspectionLoanId ==. lid]
        [Asc InspectionPerformedAt, Asc InspectionId]
    inspectionRows <- forM inspections $ \(Entity iid inspection) -> do
        inspector <- runDB $ getJust $ inspectionInspectorId inspection
        pure (iid, inspection, inspector)
    now <- liftIO getCurrentTime
    let isOwner = uid == equipmentOwnerId equipment
        canReturn = isOwner && isNothing (loanReturnedAt loan)
    defaultLayout $ do
        setTitle "Emprestimo"
        [whamlet|
            <h1>Emprestimo de #{equipmentName equipment}
            <p>Proprietario: #{userName owner}
            <p>Solicitante: #{userName borrower}
            <p>#{loanSituation now loan}
            <p>Retirada: #{displayTime $ loanCheckedOutAt loan}
            <p>Prazo: #{displayTime $ loanDueAt loan}
            $maybe returned <- loanReturnedAt loan
                <p>Devolucao: #{displayTime returned}
            <h2>Inspecoes
            $forall (iid, inspection, inspector) <- inspectionRows
                <section>
                    <h3>#{inspectionLabel $ inspectionKind inspection}
                    <p>#{conditionLabel $ inspectionCondition inspection}
                    <p>#{inspectionNotes inspection}
                    <p>Responsavel: #{userName inspector}
                    <p>#{displayTime $ inspectionPerformedAt inspection}
                    $if isOwner
                        <p>
                            <a href=@{InspectionEditR iid}>Corrigir observacoes
            $if canReturn
                <p>
                    <a .btn.btn-primary href=@{ReturnLoanR lid}>Registrar devolucao e inspecao final
            <p>
                <a href=@{RequestR $ loanSourceRequestId loan}>Solicitacao e endereco autorizado
        |]

inspectionLabel :: InspectionKind -> Text
inspectionLabel CheckoutInspection = "Retirada"
inspectionLabel ReturnInspection = "Devolucao"

loanOwner :: LoanId -> Handler UserId
loanOwner lid = do
    loan <- runDB $ get404 lid
    checkoutOwner $ loanSourceRequestId loan

getReturnLoanR :: LoanId -> Handler Html
getReturnLoanR lid = do
    _ <- loanOwner lid
    (widget, enctype) <- generateFormPost $ conditionNotesForm "Condicao na devolucao *"
    editPage "Confirmar devolucao e inspecao final" (ReturnLoanR lid) widget enctype

postReturnLoanR :: LoanId -> Handler Html
postReturnLoanR lid = do
    uid <- loanOwner lid
    submitForm "Confirmar devolucao e inspecao final" (ReturnLoanR lid)
        (conditionNotesForm "Condicao na devolucao *") $ \(condition, notes) -> do
            returnLoan uid lid condition notes
            pure $ LoanR lid

inspectionOwner :: InspectionId -> Handler (UserId, Inspection)
inspectionOwner iid = do
    inspection <- runDB $ get404 iid
    uid <- loanOwner $ inspectionLoanId inspection
    pure (uid, inspection)

notesForm :: Inspection -> Form Text
notesForm inspection = renderDivs $
    fromMaybe "" <$> aopt (requiredText 4000) (textSettings "Observacoes" "notes")
        (Just $ Just $ inspectionNotes inspection)

getInspectionEditR :: InspectionId -> Handler Html
getInspectionEditR iid = do
    (_, inspection) <- inspectionOwner iid
    (widget, enctype) <- generateFormPost $ notesForm inspection
    editPage "Corrigir apenas observacoes da inspecao" (InspectionEditR iid) widget enctype

postInspectionEditR :: InspectionId -> Handler Html
postInspectionEditR iid = do
    (uid, inspection) <- inspectionOwner iid
    submitForm "Corrigir apenas observacoes da inspecao" (InspectionEditR iid)
        (notesForm inspection) $ \notes -> do
            correctInspectionNotes uid iid notes
            pure $ LoanR $ inspectionLoanId inspection

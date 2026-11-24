{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Loan where

import Import
import Lending
import Handler.LendingCommon

inspectionForm :: Form (EquipmentCondition, Text)
inspectionForm = renderDivs $ (,)
    <$> areq conditionField (textSettings "Condicao na retirada *" "condition") Nothing
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
getLoansR = do
    Entity uid _ <- requireActiveUser
    equipmentIds <- runDB $ selectKeysList [EquipmentOwnerId ==. uid] []
    requests <- runDB $ selectList
        ([LoanRequestRequesterId ==. uid] ||. [LoanRequestEquipmentId <-. equipmentIds]) []
    loans <- runDB $ selectList [LoanSourceRequestId <-. map entityKey requests]
        [Desc LoanCheckedOutAt, Desc LoanId]
    rows <- forM loans $ \(Entity lid loan) -> do
        request <- runDB $ getJust $ loanSourceRequestId loan
        equipment <- runDB $ getJust $ loanRequestEquipmentId request
        pure (lid, loan, equipment)
    now <- liftIO getCurrentTime
    defaultLayout $ do
        setTitle "Meus emprestimos"
        [whamlet|
            <h1>Meus emprestimos
            $if null rows
                <p>Nenhum emprestimo.
            $forall (lid, loan, equipment) <- rows
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2><a href=@{LoanR lid}>#{equipmentName equipment}
                        <p>Prazo: #{displayTime $ loanDueAt loan}
                        <p>#{loanSituation now loan}
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
    (_, request, equipment) <- requireRequestParticipant $ loanSourceRequestId loan
    owner <- runDB $ getJust $ equipmentOwnerId equipment
    borrower <- runDB $ getJust $ loanRequestRequesterId request
    inspections <- runDB $ selectList [InspectionLoanId ==. lid]
        [Asc InspectionPerformedAt, Asc InspectionId]
    inspectionRows <- forM inspections $ \(Entity _ inspection) -> do
        inspector <- runDB $ getJust $ inspectionInspectorId inspection
        pure (inspection, inspector)
    now <- liftIO getCurrentTime
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
            $forall (inspection, inspector) <- inspectionRows
                <section>
                    <h3>#{inspectionLabel $ inspectionKind inspection}
                    <p>#{conditionLabel $ inspectionCondition inspection}
                    <p>#{inspectionNotes inspection}
                    <p>Responsavel: #{userName inspector}
                    <p>#{displayTime $ inspectionPerformedAt inspection}
            <p><a href=@{RequestR $ loanSourceRequestId loan}>Solicitacao e endereco autorizado
        |]

inspectionLabel :: InspectionKind -> Text
inspectionLabel CheckoutInspection = "Retirada"
inspectionLabel ReturnInspection = "Devolucao"

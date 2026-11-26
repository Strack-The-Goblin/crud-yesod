{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.LoanRequest where

import Import
import Lending
import Handler.LendingCommon

requestForm :: Maybe LoanRequest -> Form (UTCTime, UTCTime, Text)
requestForm value = renderDivs $ (,,)
    <$> areq timestampField (textSettings "Inicio * (UTC-03:00)" "startsAt")
        (loanRequestStartsAt <$> value)
    <*> areq timestampField (textSettings "Fim * (UTC-03:00)" "endsAt")
        (loanRequestEndsAt <$> value)
    <*> areq (requiredText 2000) (textSettings "Finalidade *" "purpose") (loanRequestPurpose <$> value)

getRequestNewR :: EquipmentId -> Handler Html
getRequestNewR eid = do
    _ <- requireActiveUser
    _ <- runDB $ get404 eid
    (widget, enctype) <- generateFormPost $ requestForm Nothing
    editPage "Solicitar equipamento" (RequestNewR eid) widget enctype

postRequestNewR :: EquipmentId -> Handler Html
postRequestNewR eid = do
    Entity uid _ <- requireActiveUser
    _ <- runDB $ get404 eid
    submitForm "Solicitar equipamento" (RequestNewR eid) (requestForm Nothing) $ \(start, end, purpose) -> do
        rid <- saveRequest uid eid Nothing start end purpose
        pure $ RequestR rid

editableRequest :: LoanRequestId -> Handler (UserId, LoanRequest)
editableRequest rid = do
    (Entity uid _, request, _) <- requireRequestParticipant rid
    unless (loanRequestRequesterId request == uid && loanRequestStatus request == Pending) $
        permissionDenied "Somente o solicitante pode editar uma solicitacao pendente."
    pure (uid, request)

getRequestEditR :: LoanRequestId -> Handler Html
getRequestEditR rid = do
    (_, request) <- editableRequest rid
    (widget, enctype) <- generateFormPost $ requestForm $ Just request
    editPage "Editar solicitacao" (RequestEditR rid) widget enctype

postRequestEditR :: LoanRequestId -> Handler Html
postRequestEditR rid = do
    (uid, request) <- editableRequest rid
    submitForm "Editar solicitacao" (RequestEditR rid) (requestForm $ Just request) $ \(start, end, purpose) -> do
        _ <- saveRequest uid (loanRequestEquipmentId request) (Just rid) start end purpose
        pure $ RequestR rid

getRequestListR :: Handler Html
getRequestListR = requestList False False

getReceivedRequestsR :: Handler Html
getReceivedRequestsR = requestList True False

getAdminRequestsR :: Handler Html
getAdminRequestsR = requestList False True

requestList :: Bool -> Bool -> Handler Html
requestList received support = do
    Entity uid _ <- if support then requireAdministrator else requireActiveUser
    page <- getPage
    equipmentIds <- runDB $ selectKeysList [EquipmentOwnerId ==. uid] []
    requests <- runDB $ selectList
        (if support then [] else if received then [LoanRequestEquipmentId <-. equipmentIds] else [LoanRequestRequesterId ==. uid])
        [Desc LoanRequestCreatedAt, Desc LoanRequestId, LimitTo 21, OffsetBy ((page - 1) * 20)]
    rows <- forM (take 20 requests) $ \(Entity rid request) -> do
        equipment <- runDB $ getJust $ loanRequestEquipmentId request
        pure (rid, request, equipment)
    let heading = if support then "Solicitacoes (suporte)" else if received then ("Solicitacoes recebidas" :: Text) else "Minhas solicitacoes"
        route = if support then AdminRequestsR else if received then ReceivedRequestsR else RequestListR
    defaultLayout $ do
        setTitle "Solicitacoes"
        [whamlet|
            <h1>#{heading}
            $if null rows
                <p>Nenhuma solicitacao.
            $forall (rid, request, equipment) <- rows
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2>
                            <a href=@{RequestR rid}>#{equipmentName equipment}
                        <p>#{statusLabel $ loanRequestStatus request}
                        <p>#{displayTime $ loanRequestStartsAt request} ate #{displayTime $ loanRequestEndsAt request}
            ^{pageNavigation route page (length requests > 20)}
        |]

reasonForm :: Form Text
reasonForm = renderDivs $ areq (requiredText 2000) (textSettings "Motivo da recusa *" "reason") Nothing

getRequestR :: LoanRequestId -> Handler Html
getRequestR rid = do
    (Entity uid user, request, equipment) <- requireRequestParticipant rid
    owner <- runDB $ getJust $ equipmentOwnerId equipment
    borrower <- runDB $ getJust $ loanRequestRequesterId request
    loan <- runDB $ getBy $ UniqueLoanRequest rid
    (reasonWidget, reasonEnctype) <- generateFormPost reasonForm
    let isOwner = uid == equipmentOwnerId equipment
        isRequester = uid == loanRequestRequesterId request
        canEdit = isRequester && loanRequestStatus request == Pending
        canCancel = (isOwner || isRequester) && loanRequestStatus request `elem` [Pending, Approved]
        canDecide = isOwner && loanRequestStatus request == Pending
        canCheckout = isOwner && loanRequestStatus request == Approved
        showAddress = isOwner || userRole user == Administrator
            || (isRequester && loanRequestStatus request `elem` [Approved, Collected])
    defaultLayout $ do
        setTitle "Solicitacao"
        [whamlet|
            <h1>Solicitacao de #{equipmentName equipment}
            <p>Solicitante: #{userName borrower}
            <p>Proprietario: #{userName owner}
            <p .request-status>#{statusLabel $ loanRequestStatus request}
            <p>#{displayTime $ loanRequestStartsAt request} ate #{displayTime $ loanRequestEndsAt request}
            <p>Finalidade: #{loanRequestPurpose request}
            $maybe reason <- loanRequestRejectionReason request
                <p>Motivo da recusa: #{reason}
            $if showAddress
                <section #pickup-address>
                    <h2>Endereco de retirada
                    <p>#{fromMaybe "" $ userStreet owner}, #{fromMaybe "" $ userAddressNumber owner}
                    <p>#{fromMaybe "" $ userAddressComplement owner}
                    <p>#{fromMaybe "" $ userNeighborhood owner} - #{fromMaybe "" $ userCity owner} / #{fromMaybe "" $ userState owner}
                    <p>CEP: #{fromMaybe "" $ userPostalCode owner}
            $else
                <p>Endereco de retirada sera exibido apos a aprovacao.
            $if canEdit
                <p>
                    <a href=@{RequestEditR rid}>Editar
                ^{actionForm (RequestDeleteR rid) "Excluir solicitacao pendente"}
            $if canCancel
                ^{actionForm (RequestCancelR rid) "Cancelar solicitacao"}
            $if canDecide
                ^{actionForm (RequestApproveR rid) "Aprovar solicitacao"}
                <form method=post action=@{RequestRejectR rid} enctype=#{reasonEnctype}>
                    ^{reasonWidget}
                    <button .btn.btn-default type=submit>Recusar
            $if canCheckout
                <p>
                    <a .btn.btn-primary href=@{CheckoutR rid}>Registrar retirada e inspecao
            $maybe Entity lid _ <- loan
                <p>
                    <a href=@{LoanR lid}>Consultar emprestimo
        |]

postRequestDeleteR :: LoanRequestId -> Handler Html
postRequestDeleteR rid = do
    (Entity uid _, _, _) <- requireRequestParticipant rid
    postEmpty
    runLending $ removeRequest uid rid
    setMessage "Solicitacao pendente excluida."
    redirect RequestListR

postRequestCancelR :: LoanRequestId -> Handler Html
postRequestCancelR rid = do
    (Entity uid _, _, _) <- requireRequestParticipant rid
    postEmpty
    runLending $ cancelRequest uid rid
    setMessage "Solicitacao cancelada; registro preservado."
    redirect $ RequestR rid

postRequestApproveR :: LoanRequestId -> Handler Html
postRequestApproveR rid = do
    (Entity uid _, _, equipment) <- requireRequestParticipant rid
    unless (equipmentOwnerId equipment == uid) $ permissionDenied "Somente o proprietario pode aprovar."
    postEmpty
    runLending $ decideRequest uid rid True ""
    setMessage "Solicitacao aprovada."
    redirect $ RequestR rid

postRequestRejectR :: LoanRequestId -> Handler Html
postRequestRejectR rid = do
    (Entity uid _, _, equipment) <- requireRequestParticipant rid
    unless (equipmentOwnerId equipment == uid) $ permissionDenied "Somente o proprietario pode recusar."
    submitForm "Recusar solicitacao" (RequestRejectR rid) reasonForm $ \reason -> do
        decideRequest uid rid False reason
        pure $ RequestR rid

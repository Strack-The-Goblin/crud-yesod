{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Admin where

import Import
import Lending
import Handler.LendingCommon

getAdminR :: Handler Html
getAdminR = do
    _ <- requireAdministrator
    defaultLayout $ do
        setTitle "Administracao"
        [whamlet|
            <h1>Administracao e suporte
            <p>Consultas incluem registros inativos e historico. Operacoes de proprietario continuam restritas ao titular.
            <ul>
                <li>
                    <a href=@{CategoriesR}>Gerenciar categorias
                <li>
                    <a href=@{AdminUsersR}>Contas e desativacao
                <li>
                    <a href=@{AdminEquipmentR}>Equipamentos e desativacao
                <li>
                    <a href=@{AdminRequestsR}>Consultar solicitacoes
                <li>
                    <a href=@{AdminLoansR}>Consultar emprestimos
        |]

getAdminUsersR :: Handler Html
getAdminUsersR = do
    _ <- requireAdministrator
    page <- getPage
    accounts <- runDB $ selectList [] [Asc UserName, Asc UserId, LimitTo 21, OffsetBy ((page - 1) * 20)]
    defaultLayout $ do
        setTitle "Contas (suporte)"
        [whamlet|
            <h1>Contas (suporte)
            $if null accounts
                <p>Nenhuma conta.
            $forall Entity uid user <- take 20 accounts
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2>
                            <a href=@{AdminUserR uid}>#{userName user}
                        <p>Login: #{userIdent user}
                        $if userActive user
                            <p>Ativa
                            ^{actionForm (AdminUserDeactivateR uid) "Desativar conta"}
                        $else
                            <p>Desativada
            ^{pageNavigation AdminUsersR page (length accounts > 20)}
        |]

getAdminUserR :: UserId -> Handler Html
getAdminUserR uid = do
    _ <- requireAdministrator
    user <- runDB $ get404 uid
    equipment <- runDB $ selectList [EquipmentOwnerId ==. uid] [Asc EquipmentName, Asc EquipmentId]
    requests <- runDB $ selectList [LoanRequestRequesterId ==. uid] [Desc LoanRequestCreatedAt, Desc LoanRequestId]
    commitments <- runDB $ userHasCommitments uid
    defaultLayout $ do
        setTitle "Conta (suporte)"
        [whamlet|
            <h1>#{userName user}
            <p>Login: #{userIdent user}
            $if userActive user
                <p>Conta ativa
            $else
                <p>Conta desativada
            $if userRole user == Administrator
                <p>Administrador
            $else
                <p>Aluno
            <section #pickup-address>
                <h2>Endereco (suporte autorizado)
                <p>#{fromMaybe "" $ userStreet user}, #{fromMaybe "" $ userAddressNumber user}
                <p>#{fromMaybe "" $ userAddressComplement user}
                <p>#{fromMaybe "" $ userNeighborhood user} - #{fromMaybe "" $ userCity user} / #{fromMaybe "" $ userState user}
                <p>CEP: #{fromMaybe "" $ userPostalCode user}
            $if commitments
                <p .alert.alert-warning>Desativacao bloqueada por reservas aprovadas ou emprestimos abertos.
            $if userActive user
                ^{actionForm (AdminUserDeactivateR uid) "Desativar conta"}
            <h2>Equipamentos
            $if null equipment
                <p>Nenhum equipamento.
            $forall Entity eid item <- equipment
                <p>
                    <a href=@{EquipmentR eid}>#{equipmentName item}
            <h2>Solicitacoes como solicitante
            $if null requests
                <p>Nenhuma solicitacao.
            $forall Entity rid item <- requests
                <p>
                    <a href=@{RequestR rid}>#{loanRequestPurpose item} - #{statusLabel $ loanRequestStatus item}
        |]

postAdminUserDeactivateR :: UserId -> Handler Html
postAdminUserDeactivateR uid = do
    Entity actor _ <- requireAdministrator
    _ <- runDB $ get404 uid
    postEmpty
    runLending $ deactivateAccount actor uid
    when (actor == uid) $ clearCreds False
    setMessage "Conta desativada; historico preservado."
    redirect $ if actor == uid then HomeR else AdminUsersR

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Maintenance where

import Import
import Lending
import Handler.LendingCommon

maintenanceForm :: Text -> Maybe Text -> Form Text
maintenanceForm label initial = renderDivs $
    areq (requiredText 2000) (textSettings label "value") initial

getEquipmentMaintenanceR :: EquipmentId -> Handler Html
getEquipmentMaintenanceR eid = do
    (Entity uid _, equipment) <- requireEquipmentReader eid
    records <- runDB $ selectList [MaintenanceEquipmentId ==. eid]
        [Desc MaintenanceStartedAt, Desc MaintenanceId]
    (widget, enctype) <- generateFormPost $ maintenanceForm "Motivo *" Nothing
    let isOwner = uid == equipmentOwnerId equipment
    defaultLayout $ do
        setTitle "Manutencoes"
        [whamlet|
            <h1>Manutencoes de #{equipmentName equipment}
            $if null records
                <p>Nenhuma manutencao.
            $forall Entity mid maintenance <- records
                <p>
                    <a href=@{MaintenanceR mid}>#{maintenanceReason maintenance}
                    $if isNothing $ maintenanceFinishedAt maintenance
                        <span> - Aberta
                    $else
                        <span> - Encerrada
            $if isOwner
                <h2>Abrir manutencao
                <form method=post action=@{EquipmentMaintenanceR eid} enctype=#{enctype}>
                    ^{widget}
                    <button .btn.btn-primary type=submit>Abrir manutencao
        |]

postEquipmentMaintenanceR :: EquipmentId -> Handler Html
postEquipmentMaintenanceR eid = do
    (Entity uid _, _) <- requireEquipmentOwner eid
    submitForm "Abrir manutencao" (EquipmentMaintenanceR eid) (maintenanceForm "Motivo *" Nothing) $ \reason -> do
        mid <- openMaintenance uid eid reason
        pure $ MaintenanceR mid

maintenanceOwner :: MaintenanceId -> Handler (UserId, Maintenance)
maintenanceOwner mid = do
    maintenance <- runDB $ get404 mid
    (Entity uid _, _) <- requireEquipmentOwner $ maintenanceEquipmentId maintenance
    pure (uid, maintenance)

getMaintenanceR :: MaintenanceId -> Handler Html
getMaintenanceR mid = do
    maintenance <- runDB $ get404 mid
    (Entity uid _, equipment) <- requireEquipmentReader $ maintenanceEquipmentId maintenance
    (editWidget, editEnctype) <- generateFormPost $
        maintenanceForm "Motivo *" $ Just $ maintenanceReason maintenance
    (finishWidget, finishEnctype) <- generateFormPost $ maintenanceForm "Resultado *" Nothing
    let isOwner = uid == equipmentOwnerId equipment
    defaultLayout $ do
        setTitle "Manutencao"
        [whamlet|
            <h1>Manutencao
            <p>#{maintenanceReason maintenance}
            <p>Inicio: #{displayTime $ maintenanceStartedAt maintenance}
            $maybe end <- maintenanceFinishedAt maintenance
                <p>Conclusao: #{displayTime end}
                <p>Resultado: #{fromMaybe "" $ maintenanceResult maintenance}
            $nothing
                <p>Manutencao aberta.
                $if isOwner
                    <h2>Editar motivo
                    <form method=post action=@{MaintenanceEditR mid} enctype=#{editEnctype}>
                        ^{editWidget}
                        <button type=submit>Salvar motivo
                    <h2>Concluir manutencao
                    <form method=post action=@{MaintenanceFinishR mid} enctype=#{finishEnctype}>
                        ^{finishWidget}
                        <button .btn.btn-primary type=submit>Concluir
            <p>
                <a href=@{EquipmentMaintenanceR $ maintenanceEquipmentId maintenance}>Voltar as manutencoes
        |]

postMaintenanceEditR :: MaintenanceId -> Handler Html
postMaintenanceEditR mid = do
    (uid, maintenance) <- maintenanceOwner mid
    submitForm "Editar motivo" (MaintenanceEditR mid)
        (maintenanceForm "Motivo *" $ Just $ maintenanceReason maintenance) $ \reason -> do
            changeMaintenance uid mid False reason
            pure $ MaintenanceR mid

postMaintenanceFinishR :: MaintenanceId -> Handler Html
postMaintenanceFinishR mid = do
    (uid, _) <- maintenanceOwner mid
    submitForm "Concluir manutencao" (MaintenanceFinishR mid)
        (maintenanceForm "Resultado *" Nothing) $ \result -> do
            changeMaintenance uid mid True result
            pure $ MaintenanceR mid

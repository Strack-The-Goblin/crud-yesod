{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.LendingCommon where

import Import
import Lending
import qualified Data.Text as T
import qualified Data.Time as Time

runLending :: SqlPersistT Handler a -> Handler a
runLending action = do
    result <- try $ runDB action
    case result of
        Right value -> pure value
        Left (LendingError message) -> do
            page <- defaultLayout $ do
                setTitle "Operacao bloqueada"
                [whamlet|
                    <h1>Operacao bloqueada
                    <p .alert.alert-warning>#{message}
                    <p>
                        <a href=@{CatalogR}>Voltar ao catalogo
                |]
            sendResponseStatus status409 page

textSettings :: Text -> Text -> FieldSettings App
textSettings label name = FieldSettings (SomeMessage label) Nothing Nothing (Just name) []

requiredText :: Int -> Field Handler Text
requiredText limit = checkBool
    (\value -> not (T.null $ T.strip value) && T.length value <= limit)
    ("Preencha o campo respeitando o tamanho maximo." :: Text) textField

conditionField :: Field Handler EquipmentCondition
conditionField = selectFieldList
    [("Bom" :: Text, Good), ("Desgaste", Worn), ("Danificado", Damaged)]

conditionLabel :: EquipmentCondition -> Text
conditionLabel Good = "Bom"
conditionLabel Worn = "Desgaste"
conditionLabel Damaged = "Danificado"

statusLabel :: LoanRequestStatus -> Text
statusLabel Pending = "Pendente"
statusLabel Approved = "Aprovada"
statusLabel Rejected = "Recusada"
statusLabel Cancelled = "Cancelada"
statusLabel Collected = "Retirada"

-- Brazil's UTC-03:00 is explicit rather than depending on the server's locale.
displayTime :: UTCTime -> Text
displayTime = pack . Time.formatTime Time.defaultTimeLocale "%d/%m/%Y %H:%M (UTC-03:00)"
    . Time.utcToLocalTime (Time.minutesToTimeZone (-180))

timestampField :: Field Handler UTCTime
timestampField = checkMMap (pure . parseTimestamp) timestampInput textField
    { fieldView = \theId name attrs value required -> [whamlet|
        <input type=datetime-local id=#{theId} name=#{name} *{attrs} value=#{either id id value} step=60 :required:required>
    |]
    }
  where
    parseTimestamp :: Text -> Either Text UTCTime
    parseTimestamp input = case
            Time.parseTimeM True Time.defaultTimeLocale "%Y-%m-%dT%H:%M" (unpack input)
            <|> Time.parseTimeM True Time.defaultTimeLocale "%Y-%m-%d %H:%M" (unpack input) of
        Nothing -> Left ("Use AAAA-MM-DD HH:MM no fuso UTC-03:00." :: Text)
        Just local -> Right $ Time.localTimeToUTC (Time.minutesToTimeZone (-180)) local

timestampInput :: UTCTime -> Text
timestampInput = pack . Time.formatTime Time.defaultTimeLocale "%Y-%m-%dT%H:%M"
    . Time.utcToLocalTime (Time.minutesToTimeZone (-180))

emptyForm :: Form ()
emptyForm = renderDivs $ pure ()

postEmpty :: Handler ()
postEmpty = do
    ((result, _), _) <- runFormPost emptyForm
    case result of
        FormSuccess () -> pure ()
        _ -> permissionDenied "Formulario invalido ou token CSRF ausente."

actionForm :: Route App -> Text -> Widget
actionForm route label = do
    (widget, enctype) <- handlerToWidget $ generateFormPost emptyForm
    [whamlet|
        <form method=post action=@{route} enctype=#{enctype} onsubmit="return confirm('Confirmar esta operacao?')">
            ^{widget}
            <button .btn.btn-default type=submit>#{label}
    |]

editPage :: Text -> Route App -> Widget -> Enctype -> Handler Html
editPage title route widget enctype = defaultLayout $ do
    setTitle $ toHtml title
    [whamlet|
        <h1>#{title}
        <form method=post action=@{route} enctype=#{enctype} :needsConfirmation route:onsubmit="return confirm('Confirmar devolucao e inspecao final?')">
            ^{widget}
            <button .btn.btn-primary type=submit>Salvar
    |]

needsConfirmation :: Route App -> Bool
needsConfirmation (ReturnLoanR _) = True
needsConfirmation _ = False

getPage :: Handler Int
getPage = do
    page <- fromMaybe 1 <$> runInputGet (iopt intField "page")
    when (page < 1 || page > 100000) $ invalidArgs ["Pagina invalida."]
    pure page

pageNavigation :: Route App -> Int -> Bool -> Widget
pageNavigation route page more = [whamlet|
    <nav aria-label="Paginacao">
        $if page > 1
            <a href=@?{(route, [("page", tshow (page - 1))])}>Anterior
        <span> Pagina #{page}
        $if more
            <a href=@?{(route, [("page", tshow (page + 1))])}>Proxima
|]

submitForm :: Text -> Route App -> Form a -> (a -> SqlPersistT Handler (Route App)) -> Handler Html
submitForm title route form save = do
    ((result, widget), enctype) <- runFormPost form
    case result of
        FormSuccess value -> do
            saved <- try $ runDB $ save value
            case saved of
                Left (LendingError message) -> do
                    setMessage $ toHtml message
                    sendResponseStatus status409 =<< editPage title route widget enctype
                Right destination -> do
                    setMessage "Operacao concluida."
                    redirect destination
        _ -> editPage title route widget enctype

requireEquipmentOwner :: EquipmentId -> Handler (Entity User, Equipment)
requireEquipmentOwner eid = do
    account@(Entity uid _) <- requireActiveUser
    equipment <- runDB $ get404 eid
    unless (equipmentOwnerId equipment == uid) $ permissionDenied "Acesso exclusivo do proprietario."
    pure (account, equipment)

requireEquipmentReader :: EquipmentId -> Handler (Entity User, Equipment)
requireEquipmentReader eid = do
    account@(Entity uid user) <- requireActiveUser
    equipment <- runDB $ get404 eid
    unless (equipmentOwnerId equipment == uid || userRole user == Administrator) $
        permissionDenied "Acesso exclusivo do proprietario ou administrador."
    pure (account, equipment)

requireRequestParticipant :: LoanRequestId -> Handler (Entity User, LoanRequest, Equipment)
requireRequestParticipant rid = do
    account@(Entity uid user) <- requireActiveUser
    request <- runDB $ get404 rid
    equipment <- runDB $ get404 $ loanRequestEquipmentId request
    unless (uid == loanRequestRequesterId request || uid == equipmentOwnerId equipment
            || userRole user == Administrator) $
        permissionDenied "Acesso exclusivo dos participantes ou administrador."
    pure (account, request, equipment)

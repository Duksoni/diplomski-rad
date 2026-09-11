#import "../funkcije.typ": todo
= Архитектура система
<arhitektura>

Ово поглавље приказује архитектуру платформе. Микросервиси и њихове одговорности дати су у потпоглављу @mikroservisi. Организација кода описана је у потпоглављу @organizacija-koda, а изградња и покретање сервиса у потпоглављу @izgradnja-pokretanje.

== Микросервиси платформе
<mikroservisi>

На основу упоредног приказа стилова архитектуре из поглавља @stilovi-arhitekture и нефункционалних захтева из поглавља @nefunkcionalni-zahtevi, за платформу је изабрана микросервисна архитектура. Преглед шест сервиса платформе дат је у табели @tbl:servisi, а сервиси су формирани на основу функционалних захтева из поглавља @funkcionalni-zahtevi. Сви сервиси сем API _gateway_ сервиса имају сопствени модел и базу података, по обрасцу база података по сервису @richardson2026. Сви сервиси излажу REST интерфејс описан _OpenAPI_ спецификацијом @openapi2025. Архитектура је илустрована на слици @fig:arhitektura.

#figure(
  caption: [Микросервиси платформе],
  table(
    columns: 3,
    align: (col, row) => (left, left, left).at(col),
    inset: 6pt,
    [*Сервис*], [*Одговорности*], [*База података*],
    [Сервис за кориснике], [Регистрација, пријава, издавање и управљање JWT, управљање налозима и улогама], [_PostgreSQL_],
    [Сервис за каталог игара], [Основни подаци о играма, пратећи ентитети, претрага и преглед], [_PostgreSQL_],
    [Сервис за библиотеку], [Веза корисник-игра], [_PostgreSQL_],
    [Сервис за мултимедију], [Складиштење и обрада слика и видео снимака игара], [_MongoDB_ (метаподаци) + _MinIO_ (фајлови)],
    [Сервис за кориснички садржај], [Оцене, коментари и модерација непримереног садржаја], [_MongoDB_],
    [API _gateway_ сервис @richardson2026], [Рутирање захтева, валидација JWT, контрола приступа према улози корисника], [-],
  )
) <tbl:servisi>

#figure(
  image("../slike/arhitektura-platforme.png", width: 90%),
  caption: [
    Архитектура платформе са током комуникације између компоненти. Главни ток је представљен пуним линијама.
  ]
) <fig:arhitektura>

== Организација кода
<organizacija-koda>

Пројекат је организован као _Rust workspace_ (листинг @lst:workspace) у коме је сваки сервис посебан бинарни сандук, док су `jwt-common` и `service-common` библиотечки сандуци. Припадници _workspace_-а и зависности пројекта су декларисани у коренском `Cargo.toml` фајлу, а верзије зависности закључане `Cargo.lock` фајлом.

#figure(
```text
playlog-backend/
├── services/
│   ├── api-gateway/
│   ├── catalogue-service/
│   ├── library-service/
│   ├── multimedia-service/
│   ├── review-service/
│   └── user-service/
├── shared/
│   ├── jwt-common/
│   └── service-common/
├── Cargo.toml
└── Cargo.lock
```,
  caption: [Организација _Rust_ пројекта]
) <lst:workspace>

Унутар сваког сервиса код је организован по моделу _package by feature_ @martin2017. Фолдер `games` сервиса за каталог (листинг @lst:package-by-feature) је типичан пример: обрада захтева, пословна логика и приступ подацима раздвојени су у `handler.rs`, `service.rs` и `repository.rs` фајловима и пратећи модели у фајловима `model.rs`, `dto.rs` и `error.rs`. Сви репозиторијуми, као и складиште објеката, дефинисани су _trait_-овима, па сервисни слој не зависи од њихових конкретних имплементација.

#figure(
```text
catalogue-service/src/games/
├── dto.rs
├── error.rs
├── handler.rs
├── model.rs
├── repository.rs
└── service.rs
```,
  caption: [Пример _package by feature_ организације]
) <lst:package-by-feature>

Библиотека, као најмањи сервис, приказује комплетну структуру фајлова (листинг @lst:service-layout). Улаз у сервис (`main.rs`) учитава конфигурацију, успоставља везу са базом и покреће апликацију; `config.rs` дефинише параметре учитане из окружења, а `app.rs` спаја дељено стање и рутер у апликацију коју `main.rs` покреће. `docs.rs` дефинише структуру за генерисање _OpenAPI_ спецификације сервиса.

Дељено стање и подаци о пријављеном кориснику (_claims_) стижу _handler_-има кроз екстракторе `State` и `Extension`, како је описано у поглављу @axum.

Преостале датотеке подржавају изградњу и повезивање сервиса у платформу: `Cargo.toml` наводи зависности које сервис увози из _workspace_-а, `Dockerfile` гради слику сервиса, а `compose.yaml`, `Makefile` и `.env` датотеке га повезују у платформу. `migrations/` чува верзионисане измене шеме базе које се примењују при покретању, а `.sqlx/` кеширане упите за проверу у време компајлирања без везе са базом. 


#figure(
```text
library-service/
├── .sqlx/
├── migrations/
├── src/
│   ├── app.rs
│   ├── config.rs
│   ├── docs.rs
│   ├── dto.rs
│   ├── error.rs
│   ├── handler.rs
│   ├── main.rs
│   ├── model.rs
│   ├── repository.rs
│   └── service.rs
├── .env
├── .env.production
├── Cargo.toml
├── compose.yaml
├── Dockerfile
└── Makefile
```,
  caption: [Комплетан склоп сервиса]
) <lst:service-layout>

== Изградња и покретање сервиса
<izgradnja-pokretanje>

Сви сервиси деле исти редослед покретања (листинг @lst:service-main). Покретање почиње читањем `.env` датотеке, успостављањем праћења дијагностика и учитавањем конфигурације. Затим следе повезивање на складишта података и припрема шеме. На крају се повезани репозиторијуми и сервиси (структуре из слоја пословне логике) деле кроз заједничко стање, гради рутер  апликације и покреће опслуживање.

Корак припреме шеме разликује се по типу базе: сервиси који користе _PostgreSQL_ примењују верзионисане миграције, док они са _MongoDB_ програмски иницијализују колекције и индексе. Поједини сервиси имају и додатне кораке: сервис за мултимедију иницијализује _MinIO_, а сервис за кориснике проверава постојање налога иницијалног администратора и покреће периодични задатак за брисање истеклих _refresh_ токена. API _gateway_ сервис, како нема базу, иницијализује само дељени HTTP _proxy_ клијент за комуникацију са осталим сервисима.

#figure(
```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    init_tracing(env!("CARGO_CRATE_NAME"));
    let env = load_from_environment()?;
    let pool = init_sqlx_db(&env.database_url).await?;
    sqlx::migrate!().run(&pool).await.context("Migrations failed")?;
    // ... инстанцирање репозиторијума и сервиса ...
    let state = Arc::new(AppState { config: env.app_config, /* ... */ });
    let app = build_app(state);
    let server_address = SocketAddr::from(([0, 0, 0, 0], 3002));
    let listener = tokio::net::TcpListener::bind(&server_address).await?;
    tracing::info!("Server started. View docs at http://{}/docs", server_address);
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await?;
    Ok(())
}
```,
  caption: [Заједнички редослед покретања (скраћено из `library-service/src/main.rs`)]
) <lst:service-main>

Читање конфигурације обједињује параметре учитане из окружења (у случају сервиса за библиотеку - јавни RSA кључ и URL до сервиса за каталог) у `AppConfig`. Заједничко стање `AppState`, изграђено у `main.rs`, обједињује конфигурацију и инстанциране сервисе, а до _handler_-a стиже управо кроз екстрактор `State`.

Апликацију гради функција `build_app`: над `OpenApiRouter`-ом се региструје рута за проверу здравља (енгл. _healthcheck_), угнежђује рутер сваке целине и примењују слојеви из поглавља @axum. Помоћна функција `finalize_router` из `service_common` затим угњежђује изграђени рутер под путању `/api` и додаје интерактивну документацију на `/docs`, чиме настаје коначна апликација коју `main.rs` покреће.
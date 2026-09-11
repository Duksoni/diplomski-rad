#let format_strane = "a4"         // могуће вредности: iso-b5, a4
#let naslov = "Микросервисна платформа за каталог, управљање личном библиотеком и размену утисака о видео играма"
#let autor = "Душан Комадиновић"

// На енглеском
#let naslov_eng = "Microservice platform for cataloging, personal library management and sharing opinions on video games"
#let autor_eng = "Dušan Komadinović"

#let indeks = "SV65/2022"

// Име и презиме ментора
#let mentor = "Игор Дејановић"
// Звање: редовни професор, ванредни професор, доцент
#let mentor_zvanje = "редовни професор"

// Скинути коментаре са одговарајућих линија
#let studijski_program = "Софтверско инжењерство и информационе технологије"
//#let studijski_program = "Рачунарство и аутоматика"
// #let stepen = "Мастер академске студије"
#let stepen = "Основне академске студије"

#let godina = [#datetime.today().year()]

#let kljucne_reci = "Rust, микросервиси, софтверска архитектура, веб апликација, видео игре"
#let apstrakt = [
  Овај рад описује дизајн и имплементацију микросервисне веб платформе која нуди јединствени каталог видео игара, уређивање личне библиотеке и размену утисака међу играчима. Пет доменских сервиса је иза API _gateway_-а, сваки са сопственим складиштем по обрасцу база података по сервису. Сервиси су пројектовани за независан развој, тестирање и пуштање у рад. Налози, каталог и библиотека су у _PostgreSQL_-у, кориснички садржај и метаподаци медија у _MongoDB_-у, а слике и видео у _MinIO_-у. Серверски део је у _Rust_-у (_Axum_), уз JWT (RS256) и контролу приступа према улози на _gateway_-у и сервисима. _Nginx_ сервира _Angular_ клијент, све се покреће преко _Docker Compose_-а и демонстрирано је кроз токове каталога, библиотеке и модерације.
]

// На енглеском
#let kljucne_reci_eng = "Rust, microservices, software architecture, web application, video games"
#let apstrakt_eng = [
  This thesis presents a microservice web platform for a unified video game catalog, personal library management, and opinion sharing among players. Five domain services sit behind an API gateway, each with its own storage under the database-per-service pattern. Services are designed for independent development, testing, and deployment. Accounts, catalog, and library data reside in PostgreSQL; user content and media metadata in MongoDB; and images and video in MinIO. The backend is implemented in Rust (Axum), with JWT (RS256) and role-based access control at the gateway and across services. Nginx serves the Angular client, the platform runs via Docker Compose, and its use is demonstrated through catalog, library, and moderation flows.
]

// TODO: Текст задатка добијате од ментора. Заменити доле #lorem(100) са текстом задатка.
#let zadatak = [
    #lorem(100)
]

// TODO: Датум одбране и чланове комисије добијате од ментора
#let datum_odbrane = "01.01.2025"
#let komisija_predsednik = "Петар Петровић"
#let komisija_predsednik_zvanje = "ванредни професор"
#let komisija_clan = "Марко Марковић"
#let komisija_clan_zvanje = "доцент"

// На енглеском уписати чланове на латиници
#let komisija_predsednik_eng = "Petar Petrović"
#let komisija_clan_eng = "Marko Marković"
#let mentor_eng = "Igor Dejanović"


// Ово даље углавном не треба мењати.

#let zvanje_eng = (
     "редовни професор": "full professor",
     "ванредни професор": "assoc. professor",
     "доцент": "asist. professor",
)
#let komisija_predsednik_zvanje_eng = zvanje_eng.at(komisija_predsednik_zvanje)
#let komisija_clan_zvanje_eng = zvanje_eng.at(komisija_clan_zvanje)
#let mentor_zvanje_eng = zvanje_eng.at(mentor_zvanje)


#let vrsta_rada = if stepen == "Мастер академске студије" {
    "Дипломски - мастер рад"
} else {
    "Дипломски - бечелор рад"
}

#let oblast = "Електротехничко и рачунарско инжењерство"
#let oblast_eng = "Electrical and Computer Engineering"
#let disciplina = "Примењене рачунарске науке и информатика"
#let disciplina_eng = "Applied computer science and informatics"

#import "funkcije.typ": *
// Поглавља/страна/цитата/табела/слика/графика/прилога
#let fizicki_opis = physical()

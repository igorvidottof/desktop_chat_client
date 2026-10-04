#![recursion_limit = "256"]

pub mod api;
mod auth;
mod conversations;
mod crypto_lifecycle;
mod frb_generated;
mod matrix;
mod message_history;
mod message_send;
mod session_store;

mod synchronization;

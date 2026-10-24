
//hnsw_update_type.rs
use rusqlite::types::{ToSql, ToSqlOutput};
use rusqlite::Result;

#[derive(Clone, Copy)]
#[repr(i64)]
pub enum HnswUpdateType {
    Delete = 1,
    Upsert = 2,
}

impl ToSql for HnswUpdateType {
    fn to_sql(&self) -> Result<ToSqlOutput<'_>> {
        Ok((*self as i64).into())
    }
}

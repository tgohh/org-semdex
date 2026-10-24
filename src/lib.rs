use emacs::{Env, IntoLisp, Result, Value, defun, Error};
use std::sync::Mutex;
use std::collections::HashMap;
use mistralrs::{EmbeddingModelBuilder, EmbeddingRequest};
use hannoy::{self, Writer, Reader};
// use heed;
use rand::{SeedableRng, rngs::StdRng};

use serde::Deserialize;
use uuid::Uuid;
// use rusqlite;

use std::path::Path;
use std::time::Duration;

pub mod db;

use crate::db::queries::{ClearChangedOrgItems, GetCreateEmbeddingSpace, GetCreateHnswDb, GetCreateOrgQuery, UpsertItemsIntoHnswQueue};
use crate::db::queries::{UpsertOrgItem, MarkChangedEmbeddingsDirty, MarkChangedHnswDirty, InitializeEmbeddings, GetHnswVectorSpaceId};
use crate::db::queries::{GetOrgIds, GetOrgIdsOfQuery};
use crate::db::queries::{RemoveOrgIdsFromOrgQuery, AddOrgIdsToOrgQuery};
use crate::db::queries::{GetVectorSpaceId, GetHnswDbIdForQuery, GetDirtyEmbeddingHeadings};
use crate::db::queries::{UpsertCleanEmbedding};
use crate::db::queries::{GetHnswDimension, GetOrgEmbeddingsToAdd, GetOrgItemsToRemove, ClearHnswUpdateQueue, SetHnswAsClean};
use crate::db::queries::{GetOrgItemById};

pub mod types;
use crate::types::HnswUpdateType;

use rusqlite_migration::{Migrations, M};




// Emacs won't load the module without this.
emacs::plugin_is_GPL_compatible!();

// -----------------------------------------------------------------------------
// CUDA Runtime API
// -----------------------------------------------------------------------------

#[link(name = "cudart")]
unsafe extern "C" {
    fn cudaGetDeviceCount(count: *mut i32) -> i32;
    fn cudaSetDevice(device: i32) -> i32;
    fn cudaDeviceReset() -> i32;
}


// CUDA returns 0 for success.
fn cuda_check(code: i32, operation: &str) -> anyhow::Result<()> {
    if code == 0 {
        Ok(())
    } else {
        anyhow::bail!("{operation} failed with CUDA error {code}")
    }
}


// Reset every CUDA device visible to this process.
//
// This destroys the CUDA context/runtime state for each device.
// A future CUDA operation will initialize it again.
fn reset_all_cuda_devices() -> anyhow::Result<()> {
    unsafe {
        let mut count = 0;

        cuda_check(
            cudaGetDeviceCount(&mut count),
            "cudaGetDeviceCount",
        )?;

        for device in 0..count {
            cuda_check(
                cudaSetDevice(device),
                &format!("cudaSetDevice({device})"),
            )?;

            cuda_check(
                cudaDeviceReset(),
                &format!("cudaDeviceReset({device})"),
            )?;
        }
    }

    Ok(())
}




#[defun]
fn shutdown(embedder: &Embedder) -> Result<()> {
    // Remove the Model from the Embedder first, giving us ownership of it.
    let model = {
        let mut guard = embedder
            .model
            .lock()
            .map_err(|_| anyhow::anyhow!("model mutex poisoned"))?;

        guard.take()
    };

    if let Some(model) = model {
        // First tell mistral.rs to terminate its engine threads and destroy
        // the model.
        embedder
            .runtime
            .block_on(model.shutdown())
            .map_err(anyhow::Error::msg)?;

        // Once mistral.rs has completely shut down, destroy the CUDA
        // contexts as well.
        reset_all_cuda_devices()?;
    }

    Ok(())
}

// -----------------------------------------------------------------------------
// Emacs module initialization
// -----------------------------------------------------------------------------

// #[emacs::module]
// fn init(env: &Env) -> Result<Value<'_>> {
//     env.message("Done loading org-minstral!")
// }

#[emacs::module]
fn init(env: &Env) -> Result<Value<'_>> {
    env.message("Done loading!")
}


struct Embedder {
    runtime: tokio::runtime::Runtime,
    model_name: String,
    model: Mutex<Option<mistralrs::Model>>
    // model: mistralrs::Model,
}


#[derive(Debug, Deserialize)]
struct OrgRecord {
    org_uuid: Uuid,
    heading: String,
    tags: Vec<String>,
    todo: Option<String>,
    file: String,
    linenumber: u64,
}


// this is a structure to capture the essential information about a model, including:
// 1. its hugging face name
// 2. its embedding vector length
#[derive(Debug, Deserialize)]
pub struct EmbeddingModelSummary {
    vector_space_name: String,
    hugging_face_name: String,
    vector_length: i64
    // TODO: incorporate more _actual_ information so this becomes more exhaustive/good
}

struct HannoyDb {
    db: hannoy::Database<hannoy::distances::Cosine>,
    env: heed::Env
}


fn get_embedding_model_info() -> HashMap<String, EmbeddingModelSummary> {
    let mut embedding_model_hashmap: HashMap<String, EmbeddingModelSummary> = HashMap::new();
    let embedding_qwen_0dot8_info = EmbeddingModelSummary{
        vector_space_name: "qwen_embedding_0.6B".to_string(),
        hugging_face_name: "Qwen/Qwen3-Embedding-0.6B".to_string(),
        vector_length: 1024,
    };
    embedding_model_hashmap.insert(
        "qwen_embedding_0.6B".to_string(),
        embedding_qwen_0dot8_info
    );
    let embedding_qwen_4B_info = EmbeddingModelSummary{
        vector_space_name: "qwen_embedding_4B".to_string(),
        hugging_face_name: "Qwen/Qwen3-Embedding-4B".to_string(),
        vector_length: 2560
    };
    embedding_model_hashmap.insert("qwen_embedding_4B".to_string(), embedding_qwen_4B_info);
    return embedding_model_hashmap;
}


/// get a list of models/model names that can be used as embedding models
#[defun]
fn get_available_models<'e>(env: &'e Env)->Result<Value<'e>>{
    let available_models_hashmap: HashMap<String, EmbeddingModelSummary> = get_embedding_model_info();
    let mut model_names_rust: Vec<String> = available_models_hashmap.keys().cloned().collect();
    model_names_rust.sort();
    let mut model_names = vec![];
    for model_name in model_names_rust{
        model_names.push(model_name.into_lisp(env)?);
    }
    return env.list(&model_names);
}
/// load the model named MODEL-NAME
#[defun(user_ptr)]
fn load_model(model_name: String) -> Result<Embedder> {
    let runtime = tokio::runtime::Runtime::new()?;
    let model_info_hashmap = get_embedding_model_info();
    let Some(model_info) = model_info_hashmap.get(&model_name) else {
        return Err(Error::msg(format!("No model named `{model_name}` exists")));
    };
    let model = runtime.block_on(async {
        EmbeddingModelBuilder::new(&model_info.hugging_face_name)
            .build()
            .await
    })?;

    Ok(Embedder {
        runtime: runtime,
        model_name: model_name.clone(),
        model: Mutex::new(Some(model)),
    })    
}
/// Open a rusqlite sqlite connection at STRING-PATH
#[defun(user_ptr)]
fn open_sqlite_connection(string_path: String) ->emacs::Result<rusqlite::Connection> {
    let path = Path::new(&string_path);    
    let mut conn = rusqlite::Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        "#,
    )?;

    let migrations = Migrations::new(
        vec![M::up(include_str!("../sql/schema/00001_create_tables.sql"))]
    );
    let _ = migrations.to_latest(&mut conn);
    Ok(conn)
}
/// open a hannoy hnsw database in the STRING-DIRECTORY-PATH directory
#[defun(user_ptr)]
fn open_hannoy_connection(string_directory_path: String) -> Result<HannoyDb>{
    let env = unsafe {
        heed::EnvOpenOptions::new()
            .map_size(1024 * 1024 * 1024) // 1GiB
            .open(string_directory_path)?
    };
    let mut wtxn = env.write_txn()?;
    let db: hannoy::Database<hannoy::distances::Cosine> = env.create_database(&mut wtxn, None)?;
    let _ = wtxn.commit();
    return Ok(
        {
            HannoyDb{
                db,
                env
            }
        }
    )
}

/// register a query named QUERY-NAME, using model with the MODEL-NAME referencing the SQ-CONN sqlite connection. 
///
/// In this case, a query is a named object that will produce OrgRecord's, and
/// whose contents can/should be kept in sync with each other
///
/// Function should be indempotent for the same parameters
/// 
/// Returns (QUERY-ID, HNSW-ID).  
#[defun]
fn register_org_query<'e>(env: &'e Env, query_name: String, model_name: String, sq_conn: &mut rusqlite::Connection) -> Result<Value<'e>>{  
    // confirm the model is actually valid
    let available_models_hashmap: HashMap<String, EmbeddingModelSummary> = get_embedding_model_info();
    let Some(model_info) = available_models_hashmap.get(&model_name) else {
        return Err(Error::msg(format!("No model named `{model_name}` exists")));
    };
    let query_register_row = GetCreateOrgQuery::builder()
        .name(&query_name)
        .build()
        .query_one(sq_conn)?;
    let embedding_space_row = GetCreateEmbeddingSpace::builder()
        .model(&model_name)
        .hg_name(Some(model_info.hugging_face_name.as_str()))
        .dimensions(model_info.vector_length)
        .build()
        .query_one(sq_conn)?;
    let vector_space_id = embedding_space_row.vector_space_id;
    let query_id = query_register_row.query_id;
    let hnsw_db_row = GetCreateHnswDb::builder()
        .vector_space_id(vector_space_id)
        .query_id(query_id)
        .build()
        .query_one(sq_conn)?;
    let hnsw_db_idx = hnsw_db_row.hannoy_database_idx;
    let return_payload = vec![query_id.into_lisp(env)?, hnsw_db_idx.into_lisp(env)?];
    return env.list(&return_payload);
}

/// Upsert/synchronize the query items (step 1).
/// 
/// Parses the ORG-QUERY-RESULT-STRING containing serialized OrgRecords, for the
/// query with the associated QUERY-ID + HNSW-IDX, with bookkeeping done in the
/// SQ-CONN sqlite connection
#[defun]
fn upsert_items_for_query(org_query_result_string: String, query_id: i64, hnsw_idx: i64, sq_conn: &mut rusqlite::Connection)->Result<bool>{
    // first: upsert all the org items
    let org_records_for_query: Vec<OrgRecord> = serde_json::from_str(&org_query_result_string)?;
    {
        let tx = sq_conn.transaction()?;
        {
            let mut stmt = tx.prepare(UpsertOrgItem::QUERY)?;
            for record in &org_records_for_query {
                let org_id_str = record.org_uuid.to_string();
                let this_heading = &record.heading;
                let query = UpsertOrgItem::builder()
                    .org_uuid(&org_id_str)
                    .heading(&this_heading)
                    .todo(record.todo.as_deref())
                    .file(Some(&record.file))
                    .linenumber(Some(record.linenumber as i64))
                    .build();
                stmt.execute(query.as_params())?;
            }
        }
        // first layer of dirtying is done internally; can/should commit now (no rollback required)
        tx.commit()?;
    }
    let vector_space_id = GetHnswVectorSpaceId::builder().hannoy_database_idx(hnsw_idx).build().query_one(sq_conn)?;
    // initialize the embeddings (if applicable)
    let org_uuids: Vec<String> = org_records_for_query.into_iter().map(|org_item| org_item.org_uuid.to_string()).collect();    
    let current_query_org_ids_rows = GetOrgIds::builder()
        .org_uuids(&org_uuids)
        .build()
        .query_many(sq_conn)?;
    let current_query_org_ids: Vec<i64> = current_query_org_ids_rows.into_iter().map(|row| row.org_id).collect();
    // initialize the embedding vectors
    {
        let tx = sq_conn.transaction()?;
        {
            let mut stmt = tx.prepare(InitializeEmbeddings::QUERY)?;
            for org_id in &current_query_org_ids {
                let query = InitializeEmbeddings::builder()
                    .org_id(*org_id)
                    .vector_space_id(vector_space_id.vector_space_id)
                    .build();
                stmt.execute(query.as_params())?;
            }
        }
        tx.commit()?;
    }
    // propagate the dirty indices/items
    fannout_dirty_markings(sq_conn);
    // do comparison logic against the items registered against the curent query
    propagate_org_query_changes(current_query_org_ids, query_id, hnsw_idx, sq_conn)?; 
    return Ok(true);
}


fn diff_memberships(
    old_ids: &[i64],
    new_ids: &[i64],
) -> (Vec<i64>, Vec<i64>) {
    let mut added = Vec::new();
    let mut removed = Vec::new();

    let mut i = 0;
    let mut j = 0;

    while i < old_ids.len() && j < new_ids.len() {
        match old_ids[i].cmp(&new_ids[j]) {
            std::cmp::Ordering::Less => {
                removed.push(old_ids[i]);
                i += 1;
            }
            std::cmp::Ordering::Greater => {
                added.push(new_ids[j]);
                j += 1;
            }
            std::cmp::Ordering::Equal => {
                i += 1;
                j += 1;
            }
        }
    }

    removed.extend_from_slice(&old_ids[i..]);
    added.extend_from_slice(&new_ids[j..]);

    (added, removed)
}


fn fannout_dirty_markings(conn: &mut rusqlite::Connection){
    let _ = MarkChangedEmbeddingsDirty::builder().build().execute(conn);
    let _ = MarkChangedHnswDirty::builder().build().execute(conn);
    let _ = ClearChangedOrgItems::builder().build().execute(conn);
}

fn propagate_org_query_changes(current_query_org_ids: Vec<i64>, query_id: i64, hnsw_idx: i64, sq_conn: &mut rusqlite::Connection)->Result<()>{
    // get the previous set of org ids
    let known_previous_query_org_ids_rows = GetOrgIdsOfQuery::builder()
        .query_id(query_id)
        .build()
        .query_many(sq_conn)?;
    let known_previous_query_org_ids: Vec<i64> = known_previous_query_org_ids_rows.iter().map(|row| row.org_id).collect();
    // get what changed
    let (added_ids, removed_ids) = diff_memberships(&known_previous_query_org_ids, &current_query_org_ids);
    // add the new ones, and indicate they are added
    {
        let tx = sq_conn.transaction()?;
        {
            let mut stmt = tx.prepare(UpsertItemsIntoHnswQueue::QUERY)?;
            for added_id in added_ids {
                let sql_query = UpsertItemsIntoHnswQueue::builder()
                    .org_id(added_id)
                    .hannoy_database_idx(hnsw_idx)
                    .utype(&HnswUpdateType::Upsert)
                    .build();
                stmt.execute(sql_query.as_params())?;
            }
            for removed_id in removed_ids {
                let sql_query = UpsertItemsIntoHnswQueue::builder()
                    .org_id(removed_id)
                    .hannoy_database_idx(hnsw_idx)
                    .utype(&HnswUpdateType::Delete)
                    .build();
                stmt.execute(sql_query.as_params())?;
            }
        }
        tx.commit()?;
    }
    // now, force the removal, and insert of the items
   let _ =  RemoveOrgIdsFromOrgQuery::builder().query_id(query_id).build().execute(sq_conn);
    // now, add them all back in
    {
        let tx = sq_conn.transaction()?;
        {
            let mut stmt = tx.prepare(AddOrgIdsToOrgQuery::QUERY)?;
            for org_id in &current_query_org_ids{
                let sql_query = AddOrgIdsToOrgQuery::builder()
                    .org_id(org_id.clone())
                    .query_id(query_id)
                    .build();
                stmt.execute(sql_query.as_params())?;
            }
        }
        tx.commit()?;
    }
    return Ok(());
}

/// Update the embedding vectors for the query (step 2)
///
#[defun]
fn update_embeddings(env: &Env, query_id: i64, batch_size: i64, embedding_model: &Embedder, sq_conn: &mut rusqlite::Connection)->Result<()>{
    let guard = embedding_model.model.lock().map_err(|_| anyhow::anyhow!("model mutex poisoned"))?;
    let model = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("model has been shut down"))?;
    // get the vector space id (should be pretty fast)
    let model_name = embedding_model.model_name.clone();
    
    let _ = env.message(format!("model_name: `{model_name}`"));
    let vector_space_result = GetVectorSpaceId::builder()
        .model(&model_name)
        .build()
        .query_one(sq_conn)?;
    let vector_space_id = vector_space_result.vector_space_id;
    // get the hnsw idx/id
    let hnsw_db_result = GetHnswDbIdForQuery::builder()
        .query_id(query_id)
        .vector_space_id(vector_space_id)
        .build()
        .query_one(sq_conn)?;
    let hnsw_idx = hnsw_db_result.hannoy_database_idx;
    
    
    let mut ctr = 0;
    // now: the hard part; update all the embeddings
    loop{
        ctr = ctr +1;
        let _ = env.message(format!("starting embedding updates for batch `{ctr}`"));
        let dirty_embedding_rows = GetDirtyEmbeddingHeadings::builder()
            .query_id(query_id)
            .vector_space_id(vector_space_id)
            .batch_size(batch_size)
            .build()
            .query_many(sq_conn)?;
        if dirty_embedding_rows.is_empty(){
            break;
        }
        let mut this_embedding_request_builder = EmbeddingRequest::builder();
        for dirty_embedding_row in &dirty_embedding_rows {
            this_embedding_request_builder = this_embedding_request_builder.add_prompt(dirty_embedding_row.heading.clone());
        }
        // money shot!!!!
        let embedding_vectors = embedding_model.runtime.block_on(
            async {
                model.generate_embeddings(
                    this_embedding_request_builder
                ).await
            }
        )?;
        assert_eq!(embedding_vectors.len(), dirty_embedding_rows.len());
        // update/upsert the impacted embedding vectors
        {
            let tx = sq_conn.transaction()?;
            {
                let mut emb_stmt = tx.prepare(UpsertCleanEmbedding::QUERY)?;
                let mut hnsw_stmt =  tx.prepare(UpsertItemsIntoHnswQueue::QUERY)?;
                    for (dirty_embedding_row, embedding) in dirty_embedding_rows
                        .iter()
                        .zip(embedding_vectors.iter()){
                            let embedding_bytes = embedding_to_bytes(embedding);
                            let clean_embedding_sql_query = UpsertCleanEmbedding::builder()
                                .org_id(dirty_embedding_row.org_id)
                                .vector_space_id(vector_space_id)
                                .embedding(Some(&embedding_bytes))
                                .build();
                            let hnsw_upsert_sql_query = UpsertItemsIntoHnswQueue::builder()
                                .hannoy_database_idx(hnsw_idx)
                                .org_id(dirty_embedding_row.org_id)
                                .utype(&HnswUpdateType::Upsert)
                                .build();
                            emb_stmt.execute(clean_embedding_sql_query.as_params())?;
                            hnsw_stmt.execute(hnsw_upsert_sql_query.as_params())?;
                }
            }
            let _ = tx.commit()?;
        }
        let _ = env.message(format!("finished embedding updates for batch `{ctr}`"));
    }
    return Ok(());
}

fn embedding_to_bytes(embedding: &[f32]) -> Vec<u8> {
    embedding
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect()
}

fn bytes_to_embedding(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|chunk| {
            f32::from_le_bytes([
                chunk[0],
                chunk[1],
                chunk[2],
                chunk[3],
            ])
        })
        .collect()
}

/// Update the HNSW graph (Step 3)
#[defun]
fn update_hnsw_graph(hnsw_idx: i64, hannoy_conn: &mut HannoyDb, sq_conn: &mut rusqlite::Connection) -> Result<()>{
    let mut rng = StdRng::seed_from_u64(42);
    // get the database idx, and the vector space dimensions
    let vector_dimension_result = GetHnswDimension::builder()
        .hannoy_database_idx(hnsw_idx)
        .build()
        .query_one(sq_conn)?;
    // set up hannoy writer
    let mut wtxn = hannoy_conn.env.write_txn()?;
    let hnsw_writer = Writer::new(hannoy_conn.db, hnsw_idx as u16, vector_dimension_result.dimensions as usize);
    // get the items I need to add
    let hnsw_items_to_add_results = GetOrgEmbeddingsToAdd::builder()
        .hannoy_database_idx(hnsw_idx)
        .vector_space_id(vector_dimension_result.vector_space_id)
        .build()
        .query_many(sq_conn)?;
    for hsnw_item_to_add in hnsw_items_to_add_results {
        let Some(embedding_vector_bytes) = hsnw_item_to_add.embedding else {
            return Err(Error::msg(format!("Unable to add empty embedding vector to hsnw graph; check process order")));
        };
        let embedding_vector = bytes_to_embedding(&embedding_vector_bytes);
        let idx = hsnw_item_to_add.org_id as u32;
        hnsw_writer.add_item(& mut wtxn, idx, &embedding_vector)?;
    }
    // get the items I need to delete
    let hnsw_items_to_remove = GetOrgItemsToRemove::builder()
        .hannoy_database_idx(hnsw_idx)
        .vector_space_id(vector_dimension_result.vector_space_id)
        .build()
        .query_many(sq_conn)?;
    for hnsw_item_to_remove in hnsw_items_to_remove {
        let idx = hnsw_item_to_remove.org_id as u32;
        hnsw_writer.del_item(& mut wtxn, idx)?;
    }
    let mut builder = hnsw_writer.builder(&mut rng);
    let _ = builder.ef_construction(100).build::<16,32>(&mut wtxn);
    let _ = wtxn.commit();
    // now, clear the queue
    ClearHnswUpdateQueue::builder().hannoy_database_idx(hnsw_idx).build().execute(sq_conn)?;
    // now, mark the hannoy database as no longer requiring a rebuild
    SetHnswAsClean::builder().hannoy_database_idx(hnsw_idx).build().execute(sq_conn)?;
    return Ok(());
}

/// Make use of the semantic embeddings, and find, within a given
/// query+embedding space, the semantic matches
#[defun]
fn get_semantic_matches<'e>(env: &'e Env, match_string: String, num_matches: usize, hnsw_idx: i64, embedder: &Embedder, hannoy_conn: &HannoyDb, sq_conn: &mut rusqlite::Connection)->Result<Value<'e>>{
    let guard = embedder.model.lock().map_err(|_| anyhow::anyhow!("model mutex poisoned"))?;
    let model = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("model has been shut down"))?;

    let these_embedding_queries = embedder.runtime.block_on(async {
        model
            .generate_embeddings(
                EmbeddingRequest::builder().add_prompt(match_string)
            )
            .await
    })?;
    // there should only be one
    let this_embedding_query = &these_embedding_queries[0];
    let rtxn = hannoy_conn.env.read_txn()?;
    let reader = Reader::<hannoy::distances::Cosine>::open(&rtxn, hnsw_idx as u16, hannoy_conn.db)?;
    let nns = reader.nns(num_matches).ef_search(num_matches+1).by_vector(&rtxn, this_embedding_query)?.into_nns();
    let mut matched_items = vec![];
    for (org_id, _) in nns {
        let this_result = GetOrgItemById::builder()
            .org_id(org_id as i64)
            .build()
            .query_one(sq_conn)?;
        matched_items.push(this_result.heading.into_lisp(env)?);
    }
    return env.list(&matched_items);
}




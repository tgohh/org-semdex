--============================= Creation Commands =============================

-- name: GetCreateOrgQuery :one
INSERT INTO org_queries (name)
VALUES (?)
ON CONFLICT(name) DO UPDATE
SET name = excluded.name
RETURNING query_id;


-- name: GetCreateEmbeddingSpace :one
INSERT INTO embedding_spaces (
  model,
  hg_name,
  dimensions
) VALUES (?, ?, ?)
ON CONFLICT (model) DO UPDATE
SET
model	= EXCLUDED.model,
hg_name = EXCLUDED.hg_name,
dimensions = EXCLUDED.dimensions
RETURNING vector_space_id;


-- name: GetCreateHnswDb :one
INSERT INTO hnsw_databases (
query_id, vector_space_id
) VALUES (?, ?)
ON CONFLICT (query_id, vector_space_id) DO UPDATE
SET
query_id        = EXCLUDED.query_id,
vector_space_id = EXCLUDED.vector_space_id
  RETURNING hannoy_database_idx;

--======================== Insert items into org_items database ========================
-- name: UpsertOrgItem :exec
INSERT INTO org_items (
    org_uuid,
    heading,
    todo,
    file,
    linenumber
)
VALUES (?, ?, ?, ?, ?)

ON CONFLICT(org_uuid) DO UPDATE SET
    heading = excluded.heading,
    todo = excluded.todo,
    file = excluded.file,
    linenumber = excluded.linenumber;


--=================== Insert items into embeddings database ===================
-- name: InitializeEmbeddings :exec
INSERT INTO org_item_embeddings (
  org_id,
  vector_space_id,
  embedding_needs_update
) Values (?, ?, TRUE)
ON CONFLICT (org_id, vector_space_id) DO NOTHING;
--=========================== Dirty Fanout Commands ===========================


-- name: MarkChangedEmbeddingsDirty :exec
UPDATE org_item_embeddings
SET embedding_needs_update = TRUE
WHERE embedding_needs_update = FALSE
  AND org_id IN (
      SELECT org_id
      FROM org_items_changed
  );

-- name: MarkChangedHnswDirty :exec
UPDATE hnsw_databases
SET hnsw_update_required = TRUE
WHERE hnsw_update_required = FALSE
  AND query_id IN (
      SELECT query_id
      FROM org_item_query_memberships
      WHERE org_id IN (
          SELECT org_id
          FROM org_items_changed
      )
  );


-- name: ClearChangedOrgItems :exec
DELETE FROM org_items_changed;

--==================== Query/HNSW record updating commands ====================


-- name: GetOrgIds :many
SELECT org_id
FROM org_items
WHERE org_uuid IN (sqlc.slice('org_uuids'))
ORDER BY org_id;


-- name: GetOrgIdsOfQuery :many
SELECT org_id FROM org_item_query_memberships where query_id = ? ORDER BY org_id;

-- then, sort/compare on the Rust side if inconsistent, find out which ones
-- (Rust side), are already there, are new, or are no longer valid. Each will
-- need to be marked in the udpate queue. 

-- name: UpsertItemsIntoHnswQueue :exec
INSERT INTO hnsw_update_queue
	    (
	      hannoy_database_idx,
	      org_id,
	      utype
	    )
VALUES (?, ?, ?)
ON CONFLICT (hannoy_database_idx, org_id)
DO UPDATE SET
hannoy_database_idx = excluded.hannoy_database_idx,
org_id = excluded.org_id,
utype = excluded.utype;

-- AFTER the queue is updated: update the query memberships to make the query memberships valid

-- name: RemoveOrgIdsFromOrgQuery :exec
DELETE FROM org_item_query_memberships where query_id = ?;

-- name: AddOrgIdsToOrgQuery :exec
INSERT INTO org_item_query_memberships (
org_id,
query_id
) VALUES (?, ?);


--========================= Embedding Update Commands =========================
-- at this point, the query memberships are valid. Rust then should grab the
-- org-ids that need an updated embedding vector, IF they are part of the associated query

-- name: GetHnswVectorSpaceId :one
SELECT vector_space_id from hnsw_databases WHERE hannoy_database_idx = ?;

-- name: GetVectorSpaceId :one
SELECT vector_space_id FROM embedding_spaces
WHERE model = ?;

-- name: GetHnswDbIdForQuery :one
SELECT hannoy_database_idx FROM hnsw_databases WHERE
  query_id = ? AND vector_space_id = ?;


-- name: GetDirtyEmbeddingHeadings :many
SELECT org_items.org_id, org_items.heading
FROM org_item_query_memberships
JOIN org_item_embeddings
  ON org_item_embeddings.org_id = org_item_query_memberships.org_id
JOIN org_items
  ON org_items.org_id = org_item_query_memberships.org_id
WHERE org_item_query_memberships.query_id = ?
  AND org_item_embeddings.vector_space_id = ?
  AND org_item_embeddings.embedding_needs_update = TRUE
LIMIT sqlc.arg(batch_size);

-- next mark these vectors as "clean"

-- name: UpsertCleanEmbedding :exec
INSERT INTO org_item_embeddings (
    org_id,
    vector_space_id,
    embedding,
    embedding_needs_update
)
VALUES (?, ?, ?, FALSE)
ON CONFLICT (org_id, vector_space_id)
DO UPDATE SET
    embedding = excluded.embedding,
    embedding_needs_update = FALSE;


-- Now: the embeddings are updated. Each item's association with its respective
-- query has been updated. A queue of org_ids has been created for hannoy updating
--======================= Hannoy Insert/Delete Tasklist =======================

-- since I think it might be easier to do this piecemeal

-- name: GetOrgEmbeddingsToAdd :many
SELECT hnsw_update_queue.org_id, org_item_embeddings.embedding
 FROM hnsw_update_queue
JOIN org_item_embeddings
  ON hnsw_update_queue.org_id = org_item_embeddings.org_id
 WHERE hnsw_update_queue.hannoy_database_idx = ? AND org_item_embeddings.vector_space_id = ? AND hnsw_update_queue.utype = 2; -- upsert

-- name: GetOrgItemsToRemove :many
SELECT hnsw_update_queue.org_id, org_item_embeddings.embedding
 FROM hnsw_update_queue
JOIN org_item_embeddings
  ON hnsw_update_queue.org_id = org_item_embeddings.org_id
 WHERE hnsw_update_queue.hannoy_database_idx = ? AND org_item_embeddings.vector_space_id = ? AND hnsw_update_queue.utype = 1; -- delete

-- name: ClearHnswUpdateQueue :exec
DELETE FROM hnsw_update_queue where hannoy_database_idx = ?;

-- Now: hannoy is ready for use!


-- name: GetHnswDimension :one
SELECT embedding_spaces.dimensions, embedding_spaces.vector_space_id FROM
  embedding_spaces
  JOIN hnsw_databases
    ON
  embedding_spaces.vector_space_id = hnsw_databases.vector_space_id
WHERE hannoy_database_idx = ?;

-- name: SetHnswAsClean :exec
UPDATE hnsw_databases SET hnsw_update_required = FALSE where hannoy_database_idx = ?;


-- now, just get it!

-- name: GetOrgItemById :one
SELECT heading from org_items where org_id = ?;

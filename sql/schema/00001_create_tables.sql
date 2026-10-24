
-- primary tables: START
-- 
-- the basics: a table of org items
CREATE TABLE IF NOT EXISTS org_items (
  org_id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_uuid TEXT NOT NULL UNIQUE,
  heading TEXT NOT NULL,
  todo TEXT,
  file TEXT,
  linenumber INTEGER,
  CHECK (org_id <= 4294967295)
);

-- The queries that might exist in this process
CREATE TABLE IF NOT EXISTS org_queries(
  query_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

-- The vector spaces in which an org item can be embedded (id, and dimension),
-- and an indication of "how" said embedding could occur
CREATE TABLE IF NOT EXISTS embedding_spaces(
  vector_space_id INTEGER PRIMARY KEY,
  model TEXT NOT NULL UNIQUE,
  hg_name TEXT,
  dimensions INTEGER NOT NULL
);

-- record of which hnsw databases need to be deleted (allowing for "typical"
-- cascade logic elsewhere)
CREATE TABLE IF NOT EXISTS hnsw_deletion_queue (
    hannoy_database_idx INTEGER PRIMARY KEY
);

-- record of which org ids need to have dirty markings fan out
CREATE TABLE IF NOT EXISTS org_items_changed (
  org_id INTEGER PRIMARY KEY,
  FOREIGN KEY (org_id) REFERENCES org_items(org_id) ON DELETE CASCADE
);

-- tales with foreign keys: START
-- The databases that exist, and the embedding spaces they reference
CREATE TABLE IF NOT EXISTS hnsw_databases (
  hannoy_database_idx INTEGER PRIMARY KEY
  CHECK (hannoy_database_idx BETWEEN 0 AND 65535),
  vector_space_id INTEGER NOT NULL,
  query_id INTEGER NOT NULL,
  hnsw_update_required BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (query_id, vector_space_id),
  FOREIGN KEY (vector_space_id) references embedding_spaces(vector_space_id) ON DELETE CASCADE,
  FOREIGN KEY (query_id) REFERENCES org_queries(query_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS hnsw_by_space
ON hnsw_databases(vector_space_id, query_id);


CREATE TABLE IF NOT EXISTS hnsw_update_queue(
  org_id INTEGER NOT NULL,
  hannoy_database_idx INTEGER NOT NULL,
  utype INTEGER NOT NULL CHECK (utype in (1, 2)),
  UNIQUE (org_id, hannoy_database_idx),
  FOREIGN KEY (org_id) REFERENCES org_items(org_id) ON DELETE CASCADE,
  FOREIGN KEY (hannoy_database_idx) REFERENCES hnsw_databases(hannoy_database_idx) ON DELETE CASCADE
);
-- TODO: make sure I should actually make use of all of these
CREATE INDEX IF NOT EXISTS hnsw_queue_by_dbidx
  ON hnsw_update_queue(hannoy_database_idx, org_id);

CREATE INDEX IF NOT EXISTS hnsw_1_queue
  ON hnsw_update_queue(hannoy_database_idx, org_id)
WHERE utype = 1;

CREATE INDEX IF NOT EXISTS hnsw_2_queue
  ON hnsw_update_queue(hannoy_database_idx, org_id)
WHERE utype = 2;

-- The memberships -- some org items are members of one query, some are members
-- of another. It varies a lot query by query
CREATE TABLE IF NOT EXISTS org_item_query_memberships(
  org_id INTEGER NOT NULL,
  query_id INTEGER NOT NULL,
  PRIMARY KEY (org_id, query_id),    
  FOREIGN KEY (org_id) REFERENCES org_items(org_id) ON DELETE CASCADE,
  FOREIGN KEY (query_id) REFERENCES org_queries(query_id) ON DELETE CASCADE
);


-- create an index that goes _backward_ too, since that could speed things up
CREATE INDEX IF NOT EXISTS memberships_by_query
  ON org_item_query_memberships(query_id, org_id);


-- The embeddings that any particular org item takes within a given embedding space
CREATE TABLE IF NOT EXISTS org_item_embeddings (
  org_id INTEGER NOT NULL,
  vector_space_id INTEGER NOT NULL,
  embedding BLOB,
  embedding_needs_update BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (org_id, vector_space_id),
  FOREIGN KEY (org_id) REFERENCES org_items(org_id) ON DELETE CASCADE,
  FOREIGN KEY (vector_space_id) REFERENCES embedding_spaces(vector_space_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS embeddings_by_space
  ON org_item_embeddings(vector_space_id, org_id);

CREATE INDEX IF NOT EXISTS dirty_embeddings
ON org_item_embeddings(vector_space_id, org_id)
WHERE embedding_needs_update = TRUE;

CREATE INDEX IF NOT EXISTS dirty_hnsw
  ON hnsw_databases(hannoy_database_idx)
  WHERE hnsw_update_required = TRUE;

-- triggers
--
-- capture which hnsw databases need to be deleted from hannoy
CREATE TRIGGER IF NOT EXISTS queue_hnsw_deletion
BEFORE DELETE ON hnsw_databases
BEGIN
    INSERT OR IGNORE INTO hnsw_deletion_queue(hannoy_database_idx)
    VALUES (OLD.hannoy_database_idx);
END;

-- capture which org_id's need to have dirty markings fanned out into other places
CREATE TRIGGER IF NOT EXISTS record_heading_change
AFTER UPDATE OF heading ON org_items
WHEN OLD.heading IS NOT NEW.heading
BEGIN
    INSERT OR IGNORE INTO org_items_changed(org_id)
    VALUES (NEW.org_id);
END;

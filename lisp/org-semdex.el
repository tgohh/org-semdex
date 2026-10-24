;;; org-semdex-lisp.el --- semdex lisp interface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  tgohh

;; Author: tgohh
;; Maintainer: tgohh
;; Created: 09 Sep 2026
;; Version: 0.1.0
;; Keywords: lisp
;; URL: 
;; Package-Requires: ((emacs "30.2"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This is the "lisp side" interfaced for the 'org-semdex' code I generated in Rust, whose github here here:
;;     https://github.com/tgohh/org-semdex
;;
;;; Code:

(require 'helm)
(require 'org-ql)
(require 'org-semdex) ;; rust module!

;; configuration variable defintiions
(defvar org-semdex-lisp/db-dir
  ""
  "Directory to place the sqlite database, and the hnsw databases."
  )

(defvar org-semdex-lisp/sqlite-db-name
  "semdex.db"
  "Sqlite database name."
  )

(defvar org-semdex-lisp/hnsw-dir-name
  "hnsw"
  "Name of directory that the hnsw data lives in."
  )


;; look here for how to make things!
(defun example/org-ql/q-active-projects ()
  `(and (tags "@st_Active")
                    (tags "@desc_Main")
                    (level 1))
  )


(cl-defstruct org-semdex-lisp/runtime
  sqlite-db
  (embedding-models (make-hash-table :test #'equal))
  hnsw-database
  ;; (hnsw-databases   (make-hash-table :test #'eql))
  )


(defvar org-semdex-lisp/runtime
  (make-org-semdex-lisp/runtime)
  "Long-lived runtime state for org-semdex.")


(cl-defstruct org-semdex-lisp/defined-semantic-query
  "Elements required to actually execute a semantic query."
  query-idx
  hnsw-idx
  embedding-model
  )

(cl-defstruct org-semdex-lisp/defined-query
  "Required elements for a defined query."
  name
  org-ql-query
  args
  (semantic-query nil :type org-semdex-lisp/defined-semantic-query)
  )

(defun org-semdex-lisp/read-date-args ()
  (list (org-read-date)))

(defvar org-semdex-lisp/query-registry
  (let ((table (make-hash-table :test 'eq)))

    
    (puthash
     'active-projects
     (make-org-semdex-lisp/defined-query
      :org-ql-query #'example/org-ql/q-active-projects)
     table
     )

    table
    )
  "Registry for queries in the semdex system."
  )

(defun org-semdex-lisp--get-create-sq-conn ()
  "Indempotently get the sq-conn."
  ;; TODO: move this into the cl-defstruct for the runtime
  (let (
	(sq-conn (org-semdex-lisp/runtime-sqlite-db org-semdex-lisp/runtime))
	(sq-path (file-name-concat org-semdex-lisp/db-dir org-semdex-lisp/sqlite-db-name))
	)
    (when (not sq-conn)
      (setq sq-conn (org-semdex-open-sqlite-connection sq-path))
      (setf (org-semdex-lisp/runtime-sqlite-db org-semdex-lisp/runtime) sq-conn)      
      )
    sq-conn
    )
  )

(defun org-semdex-lisp--get-create-hnsw-connection ()
  (let

      (
       (hnsw-conn (org-semdex-lisp/runtime-hnsw-database org-semdex-lisp/runtime))
       (hnsq-path (file-name-concat org-semdex-lisp/db-dir org-semdex-lisp/hnsw-dir-name))
       )
    (when (not hnsw-conn)
      (setq hnsw-conn (org-semdex-open-hannoy-connection hnsq-path))
      (setf (org-semdex-lisp/runtime-hnsw-database org-semdex-lisp/runtime) hnsw-conn)
      )
      hnsw-conn
    )
  )

;; my own functions for interfacing into things
(defun org-semdex-lisp/initialize-query (query-name model-name)
  (interactive (list nil))
  (when (not query-name)
    (setq query-name (intern (completing-read "query-name: " (hash-table-keys org-semdex-lisp/query-registry) nil t))))
  (when (not model-name)
    (setq model-name (completing-read "model name: " (org-semdex-get-available-models) nil t)))
  (org-semdex-lisp--ensure-initialized-query query-name model-name)
  )

(defun org-semdex-lisp/capture-embedding-model (embedding-model-name)
  (interactive (list nil))
  (let ((valid-models (org-semdex-get-available-models)))
    (when (not embedding-model-name)
      (setq embedding-model-name (completing-read "model name: " (org-semdex-get-available-models) nil t)))
    (cl-assert (member embedding-model-name valid-models))
    )
  (org-semdex-lisp--ensure-embedding-model embedding-model-name)
  )

;; internal functions
(defun org-semdex-lisp--ensure-initialized-query (query-name model-name)
  (cl-assert (member model-name (org-semdex-get-available-models)))
  (cl-assert (member query-name (hash-table-keys org-semdex-lisp/query-registry)))
  ;; initialize directories
  (org-semdex-lisp--initialize-directories)
  ;; set up the actual registries of the items from the sqlite database
  (let (
	(defined-query (gethash query-name org-semdex-lisp/query-registry))
	)
    (cl-assert defined-query)
    (let (
	  ;; unpack/grab things
	  (query-name-string (symbol-name query-name))
	  (defined-semantic-query-info (org-semdex-lisp/defined-query-semantic-query defined-query))
	  (sq-conn (org-semdex-lisp--get-create-sq-conn))
	  ;; to be computed!
	  semdex-internal-query-registration-info
	  )
      ;; make sure I have slots to put the database info into
      (when (not defined-semantic-query-info)
	(setq defined-semantic-query-info (make-org-semdex-lisp/defined-semantic-query)))
      
      (setq
       semdex-internal-query-registration-info
       (org-semdex-register-org-query query-name-string model-name sq-conn)
       )
      ;; put values in their slots
      (setf
       (org-semdex-lisp/defined-semantic-query-query-idx defined-semantic-query-info)
       (nth 0 semdex-internal-query-registration-info)
       )
      (setf (org-semdex-lisp/defined-semantic-query-hnsw-idx defined-semantic-query-info)
	    (nth 1 semdex-internal-query-registration-info))
      ;; refresh values in the original registries
      (setf (org-semdex-lisp/defined-query-semantic-query defined-query)
	    defined-semantic-query-info)
      )
    defined-query
    )
  )

(defun org-semdex-lisp--ensure-embedding-model (embedding-model-name)
  (cl-assert (member embedding-model-name (org-semdex-get-available-models)))
  (let (
	(embedding-model-hash-table (org-semdex-lisp/runtime-embedding-models org-semdex-lisp/runtime))
	this-embedding-model
	)
    (setq this-embedding-model (gethash embedding-model-name embedding-model-hash-table))
    (when (not this-embedding-model)
      
      (setq this-embedding-model (org-semdex-load-model embedding-model-name))
      (puthash embedding-model-name this-embedding-model embedding-model-hash-table)

      (setf
       (org-semdex-lisp/runtime-embedding-models org-semdex-lisp/runtime)
       embedding-model-hash-table)
      )
    this-embedding-model
    )
  )

(defun org-semdex-lisp--ensure-processed-query (query-name model-name)
  (cl-assert (member query-name (hash-table-keys org-semdex-lisp/query-registry)))
  (org-semdex-lisp--initialize-directories)
  (let (
	(sq-conn (org-semdex-lisp--get-create-sq-conn))
	defined-query
	)

    (setq defined-query (org-semdex-lisp--ensure-initialized-query query-name model-name))
    
    (let (
	  (org-query-func      (org-semdex-lisp/defined-query-org-ql-query   defined-query))
	  (org-query-args-func (org-semdex-lisp/defined-query-args           defined-query))
	  (semantic-query      (org-semdex-lisp/defined-query-semantic-query defined-query))
	  
	  org-query	  
	  org-query-string
	  )
      (if org-query-args-func
	  (setq org-query (apply org-query-func (funcall org-query-args-func)))
	(setq org-query (funcall org-query-func))
	)
      (setq org-query-string (org-semdex-lisp/generate-org-record-query-string org-query))

      (let (
	    (query-id (org-semdex-lisp/defined-semantic-query-query-idx semantic-query))
	    (hnsw-idx (org-semdex-lisp/defined-semantic-query-hnsw-idx  semantic-query))
	    )
	(org-semdex-upsert-items-for-query org-query-string query-id hnsw-idx sq-conn)
	)
      )
    )
  )

(cl-defun org-semdex-lisp--ensure-embeddings-for-query (query-name embedding-model-name &optional (batch-size 500))
  (cl-assert (member embedding-model-name (org-semdex-get-available-models)))
  (cl-assert (member query-name (hash-table-keys org-semdex-lisp/query-registry)))
  ;; this should be the initialization order, and they are all indempontent for a given query
  (org-semdex-lisp--initialize-directories)
  (org-semdex-lisp--get-create-sq-conn)
  (org-semdex-lisp--get-create-hnsw-connection)
  (org-semdex-lisp--ensure-initialized-query query-name embedding-model-name)
  (org-semdex-lisp--ensure-processed-query query-name embedding-model-name)
  (org-semdex-lisp--ensure-embedding-model embedding-model-name)  
  (let (
	(defined-query (gethash query-name org-semdex-lisp/query-registry))
	;; get this from the defined query
	semantic-query
	;; get these from the semantic query
	hnsw-idx
	query-id
	(embedding-hash-table (org-semdex-lisp/runtime-embedding-models org-semdex-lisp/runtime))
	;; get this from the hash table
	embedding-model
	;; capture extra stuff, since we need it
	(hnsw-conn (org-semdex-lisp/runtime-hnsw-database org-semdex-lisp/runtime))
	(sq-conn   (org-semdex-lisp/runtime-sqlite-db     org-semdex-lisp/runtime))
	)
    
    (setq embedding-model (gethash embedding-model-name embedding-hash-table))
    (cl-assert embedding-model)
    (setq semantic-query (org-semdex-lisp/defined-query-semantic-query     defined-query ))
    (setq hnsw-idx       (org-semdex-lisp/defined-semantic-query-hnsw-idx  semantic-query))
    (setq query-id       (org-semdex-lisp/defined-semantic-query-query-idx semantic-query))
    ;; update the embeddings (if applicable)
    (org-semdex-update-embeddings query-id batch-size embedding-model sq-conn)
    ;; update the hnsw graph for this query
    (org-semdex-update-hnsw-graph hnsw-idx hnsw-conn sq-conn)
    )
  )


(cl-defun org-semdex-lisp--build-semantic-helm-source (query-name embedding-model-name &optional (num-matches 20))
  (cl-assert (member query-name           (hash-table-keys org-semdex-lisp/query-registry)))
  (cl-assert (member embedding-model-name (org-semdex-get-available-models)))
  ;; this should basically be "everything" that needs to be done until this point
  (org-semdex-lisp--initialize-directories)
  (org-semdex-lisp--get-create-sq-conn)
  (org-semdex-lisp--get-create-hnsw-connection)
  (org-semdex-lisp--ensure-initialized-query query-name embedding-model-name)
  (org-semdex-lisp--ensure-processed-query query-name embedding-model-name)
  (org-semdex-lisp--ensure-embedding-model embedding-model-name)
  (org-semdex-lisp--ensure-embeddings-for-query query-name embedding-model-name)
  (let (
	(embedding-model (org-semdex-lisp--ensure-embedding-model embedding-model-name))
	(sq-conn   (org-semdex-lisp--get-create-sq-conn))
	(hnsw-conn (org-semdex-lisp/runtime-hnsw-database org-semdex-lisp/runtime))
	(source-name (concat (symbol-name query-name) "--" embedding-model-name))
	(defined-query (gethash query-name org-semdex-lisp/query-registry))
	semantic-query
	hnsw-idx
	query-idx
	)
    (setq semantic-query (org-semdex-lisp/defined-query-semantic-query defined-query))
    (setq hnsw-idx       (org-semdex-lisp/defined-semantic-query-hnsw-idx semantic-query))
    (setq query-idx      (org-semdex-lisp/defined-semantic-query-query-idx semantic-query))
    (helm-build-sync-source "Semantic Source!!"
      :volatile t
      :match (lambda (_candidate) t)
      ;; :match-dynamic t
      :candidates (lambda ()
		    (unless (string-empty-p helm-pattern)
		      (org-semdex-get-semantic-matches helm-pattern 20 hnsw-idx embedding-model hnsw-conn sq-conn)
		      )
		    )
      )
    )
  )


(defun org-semdex-lisp/semantic-search-for-query (query-name embedding-model-name)
  (interactive (list 
		      (intern (completing-read "query-name: " (hash-table-keys org-semdex-lisp/query-registry) nil t))
		      (completing-read "model name: " (org-semdex-get-available-models) nil t)))
  ;; (when (not query-name)
  ;;   (setq query-name (intern (completing-read "query-name: " (hash-table-keys org-semdex-lisp/query-registry) nil t))))
  ;; (when (not embedding-model-name)
  ;;   (setq embedding-model-name (completing-read "model name: " (org-semdex-get-available-models) nil t)))  
  (let (
	(semantic-helm-src (org-semdex-lisp--build-semantic-helm-source query-name embedding-model-name))
	(defined-query (org-semdex-lisp--ensure-initialized-query query-name embedding-model-name))
	org-query-func
	org-query-args-func
	org-query
	matched-heading
	)
    (setq matched-heading (helm :sources (list semantic-helm-src)
				:buffer "My Semantic Search"))
    (setq org-query-func (org-semdex-lisp/defined-query-org-ql-query defined-query))
    (setq org-query-args-func (org-semdex-lisp/defined-query-args   defined-query))
    
    (if org-query-args-func
	(setq org-query (apply org-query-func (funcall org-query-args-func)))
      (setq org-query (funcall org-query-func)))

    (org-ql-search
      (org-agenda-files)
      `(and (heading ,matched-heading)
	    ,@org-query))
    )
  )
  
  
  

(defun org-semdex-lisp--initialize-directories ()
  "Create lisp/host side required piping to make use of databases/items for Rust."
  (make-directory org-semdex-lisp/db-dir t)
  (make-directory (file-name-concat org-semdex-lisp/db-dir org-semdex-lisp/hnsw-dir-name) t)
  )

(defun org-semdex-lisp--capture-org-record ()
  "I am using this to replace the 'lambda' I had as part of the action to capture org records."
  `(
    ("org_uuid"    .  ,(org-id-get-create))
    ("heading"	   .  ,(org-get-heading t t t t))
    ("tags"        .  ,(vconcat (org-get-tags)))
    ("todo"	   .  ,(org-get-todo-state))
    ("file"	   .  ,(buffer-file-name))
    ("linenumber"  .  ,(line-number-at-pos))
    )
  )

(defun org-semdex-lisp/generate-org-record-query-string (org-ql-query)
  "Take an 'ORG-QL-QUERY' and make it usable to org-semdex."
  (json-encode
   (org-ql-select
     (org-agenda-files)
     org-ql-query
     :action #'org-semdex-lisp--capture-org-record  
     )
   )
  )


(provide 'org-semdex-lisp)
;;; org-semdex-lisp.el ends here

;;;
;;; Tools to handle PostgreSQL tables and indexes creations
;;;
(in-package pgloader.pgsql)

(defvar *pgsql-reserved-keywords* nil
  "We need to always quote PostgreSQL reserved keywords")

(defstruct pgsql-column name type-name type-mod nullable default)

(defmethod format-pgsql-column ((col pgsql-column) &key identifier-case)
  "Return a string representing the PostgreSQL column definition."
  (let* ((column-name
	  (apply-identifier-case (pgsql-column-type-name col) identifier-case))
	 (type-definition
	  (format nil
		  "~a~@[~a~]~:[~; not null~]~@[ default ~a~]"
		  (pgsql-column-type-name col)
		  (pgsql-column-type-mod col)
		  (pgsql-column-nullable col)
		  (pgsql-column-default col))))
    (format nil "~a ~22t ~a" column-name type-definition)))

(defun apply-identifier-case (identifier case)
  "Return given IDENTIFIER with CASE handled to be PostgreSQL compatible."
  (let ((case
	    (if (member identifier *pgsql-reserved-keywords* :test #'string=)
		:quote
		case)))
   (ecase case
     (:downcase (cl-ppcre:regex-replace-all
		 "[^a-zA-Z0-9]" (string-downcase identifier) "_"))
     (:quote    (format nil "\"~a\"" identifier)))))

(defun create-table-sql (table-name cols &key if-not-exists identifier-case)
  "Return a PostgreSQL CREATE TABLE statement from given COLS.

   Each element of the COLS list is expected to be of a type handled by the
   `format-pgsql-column' generic function."
  (with-output-to-string (s)
    (let ((table-name (apply-identifier-case table-name identifier-case)))
      (format s "CREATE TABLE~:[~; IF NOT EXISTS~] ~a ~%(~%"
	      if-not-exists
	      table-name))
    (loop
       for (col . last?) on cols
       for pg-coldef = (format-pgsql-column col :identifier-case identifier-case)
       do (format s "  ~a~:[~;,~]~%" pg-coldef last?))
    (format s ");~%")))

(defun drop-table-if-exists-sql (table-name &key identifier-case)
  "Return the PostgreSQL DROP TABLE IF EXISTS statement for TABLE-NAME."
  (let ((table-name (apply-identifier-case table-name identifier-case)))
    (format nil "DROP TABLE IF EXISTS ~a;~%" table-name)))

(defun create-table-sql-list (all-columns
			      &key
				if-not-exists
				include-drop
				(identifier-case :downcase))
  "Return the list of CREATE TABLE statements to run against PostgreSQL.

   The ALL-COLUMNS parameter must be a list of alist associations where the
   car is the table-name (a string) and the cdr is a column list. Each
   element of the column list is expected to be of a type handled by the
   `format-pgsql-column' generic function, such as `pgsql-column'."
  (loop
     for (table-name . cols) in all-columns
     when include-drop
     collect (drop-table-if-exists-sql table-name
				       :identifier-case identifier-case)

     collect (create-table-sql table-name cols
			       :if-not-exists if-not-exists
			       :identifier-case identifier-case)))

(defun create-tables (all-columns
		      &key
			if-not-exists
			(identifier-case :downcase)
			include-drop
			(client-min-messages :notice))
  "Create all tables in database dbname in PostgreSQL.

   The ALL-COLUMNS parameter must be a list of alist associations where the
   car is the table-name (a string) and the cdr is a column list. Each
   element of the column list is expected to be of a type handled by the
   `format-pgsql-column' generic function, such as `pgsql-column'."
  (loop
     for nb-tables from 0
     for sql in (create-table-sql-list all-columns
				       :if-not-exists if-not-exists
				       :identifier-case identifier-case
				       :include-drop include-drop)
     do (pgsql-execute sql :client-min-messages client-min-messages)
     finally (return nb-tables)))


;;;
;;; Index support: TODO
;;;
(defun create-index-sql (table-name table-oid index-name unique cols
			 &key identifier-case)
  "Return a PostgreSQL CREATE INDEX statement as a string."
  (let* ((index-name (format nil "idx_~a_~a" table-oid index-name))
	 (table-name (apply-identifier-case table-name identifier-case))
	 (index-name (apply-identifier-case index-name identifier-case))
	 (cols
	  (mapcar
	   (lambda (col) (apply-identifier-case col identifier-case)) cols)))
    (cond
      ((string= index-name "PRIMARY")
       (format nil
	       "ALTER TABLE ~a ADD PRIMARY KEY (~{~a~^, ~});" table-name cols))

      (t
       (format nil
	       "CREATE~:[~; UNIQUE~] INDEX ~a ON ~a (~{~a~^, ~});"
	       unique index-name table-name cols)))))

(defun drop-index-if-exists-sql (table-name table-oid index-name
				 &key identifier-case)
  "Return the DROP INDEX statement for PostgreSQL"
  (cond
    ((string= index-name "PRIMARY")
     (let* ((pkey-name  (format nil "~a_pkey" table-name))
	    (pkey-name  (apply-identifier-case pkey-name identifier-case))
	    (table-name (apply-identifier-case table-name identifier-case)))
       (format nil "ALTER TABLE ~a DROP CONSTRAINT ~a;" table-name pkey-name)))

    (t
     (let* ((index-name (format nil "idx_~a_~a" table-oid index-name))
	    (index-name (apply-identifier-case index-name identifier-case)))
       (format nil "DROP INDEX IF EXISTS ~a;" index-name)))))

(defun drop-index-sql-list (table-name table-oid indexes
			    &key identifier-case)
  "Return the DROP INDEX statements for given INDEXES definitions."
  (loop
     for (index-name unique cols) in indexes
     ;; no need to alter table drop constraint, when include-drop
     ;; is true we just did drop the table and created it again
     ;; anyway
     unless (string= index-name "PRIMARY")
     collect (drop-index-if-exists-sql table-name table-oid index-name
				       :identifier-case identifier-case)))

(defun create-index-sql-list (table-name table-oid indexes
			      &key identifier-case)
  "Return the CREATE INDEX statements from given INDEXES definitions."
  (loop
     for (index-name unique cols) in indexes
     collect (create-index-sql table-name table-oid index-name unique cols
			       :identifier-case identifier-case)))

(defun create-indexes-in-kernel (dbname table-name indexes kernel channel
				 &key
				   identifier-case include-drop
				   state (label "create index"))
  "Create indexes for given table in dbname, using given lparallel KERNEL
   and CHANNEL so that the index build happen in concurrently with the data
   copying."
  (let* ((lp:*kernel* kernel)
	 (table-oid
	  (with-pgsql-transaction (dbname)
	    (pomo:query
	     (format nil "select '~a'::regclass::oid" table-name) :single))))
    (pgstate-add-table state dbname label)

    (when include-drop
      (let ((drop-channel (lp:make-channel))
	    (drop-indexes
	     (drop-index-sql-list table-name table-oid indexes
				  :identifier-case identifier-case)))
	(loop
	   for sql in drop-indexes
	   do
	     (log-message :notice "~a" sql)
	     (lp:submit-task drop-channel
			     #'pgsql-execute-with-timing
			     dbname label sql state))

	;; wait for the DROP INDEX to be done before issuing CREATE INDEX
	(loop for idx in drop-indexes do (lp:receive-result drop-channel))))

    (loop
       for sql in (create-index-sql-list table-name table-oid indexes
					 :identifier-case identifier-case)
       do
	 (log-message :notice "~a" sql)
	 (lp:submit-task channel
			 #'pgsql-execute-with-timing
			 dbname label sql state))))
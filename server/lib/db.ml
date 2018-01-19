open Core

open Types
open Types.DbT
open Types.RuntimeT

module RT = Runtime

module PG = Postgresql

(* globals *)
let conn =
  new PG.connection ~host:"localhost" ~dbname:"proddb" ~user:"dark" ~password:"eapnsdc" ()

let cur_dbs : DbT.db list ref =
  ref []

let find_db table_name : DbT.db =
  match List.find ~f:(fun d -> d.actual_name = table_name) !cur_dbs with
   | Some d -> d
   | None -> failwith ("table not found: " ^ table_name)

(* ------------------------- *)
(* SQL Type Conversions; here placed to avoid OCaml circular dep issues *)
(* ------------------------- *)
let dval_to_sql (dv: dval) : string =
  match dv with
  | DInt i | DID i -> string_of_int i
  | DBool b -> if b then "true" else "false"
  | DChar c -> Char.to_string c
  | DStr s -> "'" ^ s ^ "'"
  | DFloat f -> string_of_float f
  | DNull -> "null"
  | DDate d ->
    "TIMESTAMP WITH TIME ZONE '"
    ^ Dval.string_of_date d
    ^ "'"
  | _ -> Exception.client "Not obvious how to persist this in the DB"

(* Turn db rows into list of string/type pairs - removes elements with
 * holes, as they won't have been put in the DB yet *)
let cols_for (db: db) : (string * tipe) list =
  db.cols
  |> List.filter_map ~f:(fun c ->
    match c with
    | Full (_, name), Full (_, tipe) ->
      Some (name, tipe)
    | _ ->
      None)
  |> fun l -> ("id", TID) :: l

let fetch_via_sql (sql: string) : string list list =
  sql
  |> Log.pp "sql"
  |> conn#exec ~expect:PG.[Tuples_ok]
  |> (fun res -> res#get_all_lst)

(*
 * Dear god, OCaml this is the worst
 * *)
let rec sql_to_dval (tipe: tipe) (sql: string) : dval =
  match tipe with
  | TID -> sql |> int_of_string |> DID
  | TInt -> sql |> int_of_string |> DInt
  | TTitle -> sql |> DTitle
  | TUrl -> sql |> DUrl
  | TStr -> sql |> DStr
  | TDate ->
    DDate (if sql = ""
           then Time.epoch
           else Dval.date_of_string sql)
  | TForeignKey table ->
    (* fetch here for now *)
    let id = sql |> int_of_string |> DID in
    let db = find_db table in
    fetch_by db "id" id
  | _ -> failwith ("type not yet converted from SQL: " ^ sql ^
                   (Dval.tipe_to_string tipe))
and
fetch_by db (col: string) (dv: dval) : dval =
  let (names, types) = cols_for db |> List.unzip in
  let colnames = names |> String.concat ~sep:", " in
  Printf.sprintf
    "SELECT %s FROM \"%s\" WHERE %s = %s"
    colnames db.actual_name col (dval_to_sql dv)
  |> fetch_via_sql
  |> List.map ~f:(to_obj names types)
  |> DList
and
(* PG returns lists of strings. This converts them to types using the
 * row info provided *)
to_obj (names : string list) (types: tipe list) (db_strings : string list)
  : dval =
  db_strings
  |> List.map2_exn ~f:sql_to_dval types
  |> List.zip_exn names
  |> Dval.to_dobj

let sql_tipe_for (tipe: tipe) : string =
  match tipe with
  | TAny -> failwith "todo sql type"
  | TInt -> "INT"
  | TFloat -> failwith "todo sql type"
  | TBool -> failwith "todo sql type"
  | TNull -> failwith "todo sql type"
  | TChar -> failwith "todo sql type"
  | TStr -> "TEXT"
  | TList -> failwith "todo sql type"
  | TObj -> failwith "todo sql type"
  | TIncomplete -> failwith "todo sql type"
  | TBlock -> failwith "todo sql type"
  | TResp -> failwith "todo sql type"
  | TDB -> failwith "todo sql type"
  | TID | TForeignKey _ -> "INT"
  | TDate -> "TIMESTAMP WITH TIME ZONE"
  | TTitle -> "TEXT"
  | TUrl -> "TEXT"


(* ------------------------- *)
(* frontend stuff *)
(* ------------------------- *)
let dbs_as_env (dbs: db list) : dval_map =
  dbs
  |> List.map ~f:(fun (db: db) -> (db.display_name, DDB db))
  |> DvalMap.of_alist_exn

let dbs_as_exe_env (dbs: db list) : dval_map =
  dbs_as_env dbs

(* ------------------------- *)
(* actual DB stuff *)
(* ------------------------- *)


let run_sql (sql: string) : unit =
  Log.pP "sql" sql ~stop:10000;
  ignore (conn#exec ~expect:[PG.Command_ok] sql)


let with_postgres fn =
  try
    fn ()
  with
  | PG.Error e ->
    Exception.internal ("DB error with: " ^ (PG.string_of_error e))

let key_names (vals: dval_map) : string =
  vals
  |> DvalMap.keys
  |> String.concat ~sep:", "

let val_names (vals: dval_map) : string =
  vals
  |> DvalMap.data
  |> List.map ~f:dval_to_sql
  |> String.concat ~sep:", "


let rec insert (db: db) (vals: dval_map) : int =
  let id = Util.create_id () in
  let vals = DvalMap.add ~key:"id" ~data:(DInt id) vals in
  (* split out complex objects *)
  let objs, normal =
    Map.partition_map
      ~f:(fun v -> if Dval.is_obj v then `Fst v else `Snd v) vals
  in
  let cols = cols_for db in
  (* insert complex objects into their own table, return the inserted ids *)
  let obj_id_map =
    Map.mapi
      ~f:(fun ~key:k ~data:v ->
          (* find table via coltype *)
          let table_name =
            let (cname, ctype) = List.find_exn cols ~f:(fun (n, t) -> n = k) in
            match ctype with
            | TForeignKey t -> t
            | _ -> failwith ("Expected TForeignKey, got: " ^ (show_tipe_ ctype))
          in
          let db_obj = find_db table_name in
          match v with
          | DObj m -> insert db_obj m |> DInt
          | _ -> failwith ("Expected complex object (DObj), got: " ^ (Dval.to_repr v))
        ) objs
  in
  (* merge the maps *)
  let merged = Util.merge_left normal obj_id_map in
  let _ = Printf.sprintf "INSERT into \"%s\" (%s) VALUES (%s)"
      db.actual_name (key_names merged) (val_names merged)
          |> run_sql
  in
    id

let fetch_all (db: db) : dval =
  let (names, types) = cols_for db |> List.unzip in
  let colnames = names |> String.concat ~sep:", " in
  Printf.sprintf
    "SELECT %s FROM \"%s\""
    colnames db.actual_name
  |> fetch_via_sql
  |> List.map ~f:(to_obj names types)
  |> DList



let delete db (vals: dval_map) =
  let id = DvalMap.find_exn vals "id" in
  Printf.sprintf "DELETE FROM \"%s\" WHERE id = %s"
    db.actual_name (dval_to_sql id)
  |> run_sql

let update db (vals: dval_map) =
  let id = DvalMap.find_exn vals "id" in
  let sets = vals
           |> DvalMap.to_alist
           |> List.map ~f:(fun (k,v) ->
               k ^ " = " ^ dval_to_sql v)
           |> String.concat ~sep:", " in
  Printf.sprintf "UPDATE \"%s\" SET %s WHERE id = %s"
    db.actual_name sets (dval_to_sql id)
  |> run_sql

(* ------------------------- *)
(* run all db and schema changes as migrations *)
(* ------------------------- *)
let run_migration (migration_id: id) (sql:string) : unit =
  Log.pP "sql" sql;
  Printf.sprintf
    "DO
       $do$
         BEGIN
           IF ((SELECT COUNT(*) FROM migrations WHERE id = %d) = 0)
           THEN
             %s;
             INSERT INTO migrations (id) VALUES (%d);
           END IF;
         END
       $do$;
     COMMIT;" migration_id sql migration_id
  |> run_sql

(* -------------------------
(* SQL for DB *)
 * TODO: all of the SQL here is very very easily SQL injectable.
 * This MUST be fixed before we go to production
 * ------------------------- *)

let create_table_sql (table_name: string) =
  Printf.sprintf
    "CREATE TABLE IF NOT EXISTS \"%s\" (id SERIAL PRIMARY KEY)"
    table_name

let add_col_sql (table_name: string) (name: string) (tipe: tipe) : string =
  Printf.sprintf
    "ALTER TABLE \"%s\" ADD COLUMN %s %s"
    table_name name (sql_tipe_for tipe)



(* ------------------------- *)
(* DB schema *)
(* ------------------------- *)

let create_new_db (tlid: tlid) (db: db) =
  run_migration tlid (create_table_sql db.actual_name)

(* we only add this when it is complete, and we use the ID to mark the
   migration table to know whether it's been done before. *)
let maybe_add_to_actual_db (db: db) (id: id) (col: col) : col =
  (match col with
  | Full (_, name), Full (_, tipe) ->
    run_migration id (add_col_sql db.actual_name name tipe)
  | _ ->
    ());
  col


let add_db_col colid typeid (db: db) =
  { db with cols = db.cols @ [(Empty colid, Empty typeid)]}

let set_col_name id name db =
  let set col =
    match col with
    | (Empty hid, tipe) when hid = id -> maybe_add_to_actual_db db id (Full (hid, name), tipe)
    | _ -> col in
  { db with cols = List.map ~f:set db.cols }

let set_db_col_type id tipe db =
  let set col =
    match col with
    | (name, Empty hid) when hid = id -> maybe_add_to_actual_db db id (name, Full (hid, tipe))
    | _ -> col in
  { db with cols = List.map ~f:set db.cols }





(* ------------------------- *)
(* Some initialization *)
(* ------------------------- *)
let _ =
  run_sql "CREATE TABLE IF NOT EXISTS \"migrations\" (id INT PRIMARY KEY)"

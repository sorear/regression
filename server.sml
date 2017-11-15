(*
Implements the server-side regression-test API as a CGI program.

The API is for workers to view and manipulate the job queues.
It also provides a hook for refreshing the queues:
  If there are new jobs on GitHub, they will be added as waiting.
  If there are stale jobs, they will be removed.

Each job is on exactly one list: waiting, running, stopped, aborted.
If a job changes list, it can only move to the right.

The waiting queue is refreshed as follows:

  1. Clear the waiting jobs list
  2. Get the current snapshots from GitHub (see below)
  3. Filter out from the snapshots:
    - any with the same CakeML head commit as a running job
    - any with the same snapshot (head+base+HOL commits) as a stopped job
  4. Add the remaining snapshots to the waiting jobs list

The running queue may be refreshed by removing timed out jobs. (Not implemented yet.)

Current snapshots from GitHub:

    CakeML:
      - branch "master"
      - each open, mergeable pull request
        in this case, there are two commits:
          - the pull request commit (head)
          - the master commit to merge into (base)
    HOL:
      - branch "master"
*)
use "serverLib.sml";

open serverLib

fun job id =
  let
    val f = Int.toString id
    val q = queue_of_job f
  in
    OS.Path.concat(q,f)
  end

fun claim (id,name) =
  let
    val f = Int.toString id
    val old = OS.Path.concat("waiting",f)
    val new = OS.Path.concat("running",f)
    val () =
      if OS.FileSys.access(new,[OS.FileSys.A_READ]) then
        cgi_die 500 ["job ",f, " is both waiting and running"]
      else OS.FileSys.rename{old = old, new = new}
    val out = TextIO.openAppend new
    val () = print_claimed out (name,Date.fromTimeUniv(Time.now()))
    val () = TextIO.closeOut out
    val inp = TextIO.openIn new
    val sha = get_head_sha (read_bare_snapshot inp)
              handle Option => cgi_die 500 ["job ",f," has invalid file format"]
    val () = TextIO.closeIn inp
  in
    GitHub.set_status f sha Pending
  end

fun append (id,line) =
  let
    val f = Int.toString id
    val p = OS.Path.concat("running",f)
    val out = TextIO.openAppend p handle e as IO.Io _ => (cgi_die 409 ["job ",f," is not running: cannot append"]; raise e)
  in
    print_log_entry out (Date.fromTimeUniv(Time.now()),line) before TextIO.closeOut out
  end

fun log (id,data) =
  let
    val f = Int.toString id
    val p = OS.Path.concat("running",f)
    val out = TextIO.openAppend p handle e as IO.Io _ => (cgi_die 409 ["job ",f," is not running: cannot log"]; raise e)
  in
    TextIO.output(out,data) before TextIO.closeOut out
  end

fun stop id =
  let
    val f = Int.toString id
    val old = OS.Path.concat("running",f)
    val new = OS.Path.concat("stopped",f)
    val () =
      if OS.FileSys.access(old,[OS.FileSys.A_READ]) then
        if OS.FileSys.access(new,[OS.FileSys.A_READ]) then
          cgi_die 500 ["job ",f, " is both running and stopped"]
        else OS.FileSys.rename{old = old, new = new}
      else cgi_die 409 ["job ",f," is not running: cannot stop"]
    val inp = TextIO.openIn new
    val sha = get_head_sha (read_bare_snapshot inp)
    val status = read_status inp
    val () = TextIO.closeIn inp
    val () = GitHub.set_status f sha status
  in
    ignore (
      send_email (String.concat["Job ",f,": ",#2 (GitHub.status status)])
                 (String.concat["See ",server,"/job/",f,"\n"]))
  end

fun abort id =
  let
    val f = Int.toString id
    val old = OS.Path.concat("stopped",f)
    val new = OS.Path.concat("aborted",f)
  in
    if OS.FileSys.access(old,[OS.FileSys.A_READ]) then
      if OS.FileSys.access(new,[OS.FileSys.A_READ]) then
        cgi_die 500 ["job ",f, " is both stopped and aborted"]
      else OS.FileSys.rename{old = old, new = new}
    else cgi_die 409 ["job ",f," is not stopped: cannot abort"]
  end

fun refresh () =
  let
    val snapshots = get_current_snapshots ()
    val () = clear_list "waiting"
    (* TODO: stop timed out jobs *)
    val running_ids = running()
    val stopped_ids = stopped()
    val snapshots = filter_out (same_head "running") running_ids snapshots
    val snapshots = filter_out (same_snapshot "stopped") stopped_ids snapshots
    val avoid_ids = running_ids @ stopped_ids @ aborted()
    val () = if List.null snapshots then ()
             else ignore (List.foldl (add_waiting avoid_ids) 1 snapshots)
  in () end

datatype request = Api of api | Html of html_request

fun check_auth auth ua =
  if auth = SOME (String.concat["Bearer ",cakeml_token]) orelse
     Option.map (String.isPrefix "GitHub-Hookshot/") ua = SOME true
  then ()
  else cgi_die 401 ["Unauthorized: ", Option.valOf auth handle Option => "got nothing"]

fun get_api () =
  case (OS.Process.getEnv "PATH_INFO",
        OS.Process.getEnv "REQUEST_METHOD") of
    (NONE, SOME "GET") => SOME (Html Overview)
  | (SOME path_info, SOME "GET") =>
      if String.isPrefix "/api" path_info then
        Option.map (Api o G) (get_from_string (String.extract(path_info,4,NONE)))
      else if String.isPrefix "/job/" path_info then
        Option.map (Html o DisplayJob) (id_from_string (String.extract(path_info,5,NONE)))
      else cgi_die 404 []
  | (SOME path_info, SOME "POST") =>
    let
      val () = cgi_assert (String.isPrefix "/api" path_info) 400 [path_info," is not a known endpoint"]
      val () = check_auth (OS.Process.getEnv "HTTP_AUTHORIZATION")
                          (OS.Process.getEnv "HTTP_USER_AGENT")
      val q = Option.map (fn len => TextIO.inputN(TextIO.stdIn,len))
                (Option.mapPartial Int.fromString
                  (OS.Process.getEnv "CONTENT_LENGTH"))
    in
      Option.map (Api o P)
        (post_from_string (String.extract(path_info,4,NONE)) q)
    end
  | _ => NONE

local
  fun id_list ids = String.concatWith " " (List.map Int.toString ids)
in
  fun dispatch api =
    let
      val response =
        case api of
          (G Waiting) => id_list (waiting())
        | (G (Job id)) => file_to_string (job id)
        | (P p) => post_response p
      val () =
        case api of
          (G _) => ()
        | (P Refresh) => refresh ()
        | (P (Claim x)) => claim x
        | (P (Append x)) => append x
        | (P (Log x)) => log x
        | (P (Stop x)) => stop x
        | (P (Abort x)) => abort x
    in
      write_text_response 200 response
    end
end

fun dispatch_req req =
  let in
    case req of
      (Api api) => dispatch api
    | (Html req) => html_response req
  end handle e => cgi_die 500 [exnMessage e]

fun main () =
  let
    val () = ensure_queue_dirs ()
  in
    case get_api () of
      NONE => cgi_die 400 ["bad usage"]
    | SOME req =>
      let
        val fd = acquire_lock ()
      in
        dispatch_req req before
        Posix.IO.close fd
      end
  end

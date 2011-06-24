# $Id:$
#

@load conn-id

# TODO: capture filter
redef capture_filters += { ["smb"] = "port 445" };

global smb_ports = { 139/tcp, 445/tcp } &redef;
redef dpd_config += { [ANALYZER_SMB] = [$ports = smb_ports] };

const smb_log = open_log_file("smb") &redef;
const smb_files_log = open_log_file("smb-files") &redef;


type smb_cmd_info: record {
	pid: count;
	mid: count;
	cmd: count;
	cmdstr: string;

	fidstr: string;
	# for read/writes: number of bytes read/written and offset
	file_payload: count;
	file_offset: count;

	cmdid: count;

	req_first_time: time;
	req_last_time: time;
	req_body_len: count;

	rep_first_time: time;
	rep_last_time: time;
	rep_body_len: count;

	done: bool;
};

type smb_pending_cmds: table[count, count] of smb_cmd_info;
global smb_sessions: table[conn_id] of smb_pending_cmds;

# can be used by more specific event handlers for request/reply
# matching. See nt_create_andx for an example. 
global nextcmdid = 1;

# indexed by cmdid
global smb_filenames: table[count] of string &read_expire=900secs;

# it seems Bro has issues with anonymous records of the form [cid,count] 
# so we just use a table of table
global fid_map: table[conn_id] of table[count] of string;
global next_fid = 0;

# the commands in this set are handled by a more specific event handler
# that add additional information. I.e., the smb_message event still does
# request/reply matching, but the more specific event takes care of printing. 
# It's all a hack....
global more_specific_cmds: set[count];
# Transaction commands and other commands for which request/reply matching
# doesn't work. We ignore them all.
# transaction commands re-use PID:MID. We'd have to look into the actual
# transaction command to match requests/replies. 
global smb_ignore_cmds: set[count];
event bro_init() 
	{
	add more_specific_cmds[0x2e];  # read_andx
	add more_specific_cmds[0x2f];  # write_andx
	add more_specific_cmds[0xa2];  # nt_create_andx

	add smb_ignore_cmds[0x25];  # transaction
	add smb_ignore_cmds[0x26];  # transaction_secondary
	add smb_ignore_cmds[0x32];  # transaction2
	add smb_ignore_cmds[0x33];  # transaction2_secondary
	add smb_ignore_cmds[0xA0];  # nt_transact
	add smb_ignore_cmds[0xA1];  # nt_transact_secondary

	add smb_ignore_cmds[0xA4];  # nt_cancel

	}

function smb_new_cmd_info(hdr: smb_hdr, body_len: count): smb_cmd_info
	{
	local info: smb_cmd_info;

	info$cmd = hdr$command;
	info$pid = hdr$pid;
	info$mid = hdr$mid;
	info$cmdstr = "";

	info$fidstr = "FIDxx"; 
	info$file_payload = 0;
	info$file_offset = 0;
	info$cmdid = nextcmdid;
	++nextcmdid;

	info$req_first_time = hdr$first_time;
	info$req_last_time = hdr$last_time;
	info$req_body_len = body_len;

	info$rep_first_time = double_to_time(0.0);
	info$rep_last_time = double_to_time(0.0);
	info$rep_body_len = 0;


	info$done = F;

	return info;
	}

function get_fid(cid: conn_id, fid: count): string
	{
	if (cid !in fid_map)
		fid_map[cid] = table();
	if ( fid !in fid_map[cid])
		{
		if (fid >= 0x10000)
			return "FIDxx";
		fid_map[cid][fid] = fmt("FID%d", next_fid);
		++next_fid;
		}
	return fid_map[cid][fid];
	}

function delete_fid(cid: conn_id, fid: count)
	{
	if (cid !in fid_map)
		return;
	if ( fid !in fid_map[cid])
		return;
	delete fid_map[cid][fid];
	}


function fmt_smb_hdr(hdr: smb_hdr): string 
	{
	return fmt("%.6f %.6f %d %d %d %d %d", hdr$first_time, hdr$last_time, hdr$tid, 
	           hdr$pid, hdr$mid, hdr$uid, hdr$status);

	}

function fmt_msg_prefix(cid: conn_id, is_orig: bool, hdr: smb_hdr): string
	{
	return fmt("%s %d (%d) %s", id_string(cid), is_orig, hdr$command,
			fmt_smb_hdr(hdr));
	}

function smb_log_cmd(c: connection, info: smb_cmd_info)
	{
	local msg = "";
	msg = fmt("COMMAND %s (%d) %d:%d %.6f %.6f %d %.6f %.6f %d %s %d %d %s %s %d",
			info$cmdstr, info$cmd, info$pid, info$mid, 
			info$req_first_time, info$req_last_time-info$req_first_time, info$req_body_len,
			info$rep_first_time, info$rep_last_time-info$rep_first_time, info$rep_body_len,
			info$fidstr, info$file_offset, info$file_payload, 
			c$id$orig_h, c$id$resp_h, c$id$resp_p);
	print smb_log, msg;
	}

function smb_log_cmd2(c: connection, hdr: smb_hdr)
	{
	if (c$id !in smb_sessions)
		return;
	local cur_session = smb_sessions[c$id];
	if ([hdr$pid,hdr$mid] !in cur_session)
		return;
	local info = cur_session[hdr$pid, hdr$mid];

	smb_log_cmd(c, info);
	}

function mismatch_fmt_hdr(hdr: smb_hdr, cmd: string): string
	{
	return fmt("%s %d:%d", cmd, hdr$pid, hdr$mid);
	}

function mismatch_fmt_info(info: smb_cmd_info): string
	{
	return fmt("%s %d:%d", info$cmdstr, info$pid, info$mid);
	}


function get_cmdid(cid: conn_id, hdr: smb_hdr): count
	{
	# smb_messge takes care of error / mismatch handling, so we can 
	# just punt here
	if (cid !in smb_sessions)
		return 0;
	local cur_session = smb_sessions[cid];
	if ([hdr$pid,hdr$mid] !in cur_session)
		return 0;
	local info = cur_session[hdr$pid, hdr$mid];
	return info$cmdid;
	}

function smb_set_fid_offset(cid: conn_id, hdr: smb_hdr, fid: count, offset: count)
	{
	# smb_messge takes care of error / mismatch handling, so we can 
	# just punt here
	if (cid !in smb_sessions)
		return;
	local cur_session = smb_sessions[cid];
	if ([hdr$pid,hdr$mid] !in cur_session)
		return;
	local info = cur_session[hdr$pid, hdr$mid];

	info$fidstr = get_fid(cid, fid);
	info$file_offset = offset;
	}

function smb_set_file_payload(cid: conn_id, hdr: smb_hdr, payload_len: count)
	{
	# smb_messge takes care of error / mismatch handling, so we can 
	# just punt here
	if (cid !in smb_sessions)
		return;
	local cur_session = smb_sessions[cid];
	if ([hdr$pid,hdr$mid] !in cur_session)
		return;
	local info = cur_session[hdr$pid, hdr$mid];

	info$file_payload = payload_len;
	}

# note, the smb_message event is raised before and more specific ones, so
# we use it to match requests to replies. 
# A hack, but it works
event smb_message(c: connection, hdr: smb_hdr, is_orig: bool, cmd: string, body_length: count, body: string) 
	{
	###print smb_log, fmt("%s %s %d", fmt_msg_prefix(c$id, is_orig, hdr), cmd, body_length);
	
	if (hdr$command==0x24 && hdr$mid == 0xffff)
		# opLock break notification event from server.
		# ignore it.
		return;
	if (hdr$command in smb_ignore_cmds)
		return;
	
	if (c$id !in smb_sessions)
		smb_sessions[c$id] = table();
	local cur_session = smb_sessions[c$id];

	# cleanup and log
	if ([hdr$pid,hdr$mid] in cur_session)
		if (cur_session[hdr$pid,hdr$mid]$done)
			delete cur_session[hdr$pid,hdr$mid];

	if (is_orig) 
		{
		if ([hdr$pid,hdr$mid] in cur_session)
			print smb_log, fmt("Mismatch: got a request but already have request queued: %s %s %s", 
				mismatch_fmt_info(cur_session[hdr$pid,hdr$mid]), mismatch_fmt_hdr(hdr,cmd), id_string(c$id));
		cur_session[hdr$pid, hdr$mid] = smb_new_cmd_info(hdr, body_length);
		cur_session[hdr$pid, hdr$mid]$cmdstr = cmd;
		}
	else
		{
		if ([hdr$pid,hdr$mid] !in cur_session)
			print smb_log, fmt("Mismatch: got a reply but no request queued: %s %s",  mismatch_fmt_hdr(hdr,cmd), id_string(c$id));
		else
			{
			local info = cur_session[hdr$pid, hdr$mid];
			if (info$cmd != hdr$command)
				{
				print smb_log, fmt("Mismatch: request and reply command don't match: %s %s", 
					mismatch_fmt_info(cur_session[hdr$pid,hdr$mid]), mismatch_fmt_hdr(hdr,cmd));
				delete cur_session[hdr$pid,hdr$mid];
				}
			else if (info$mid != hdr$mid || info$pid != hdr$pid)
				{
				# This really should not happen
				print smb_log, fmt("Mismatch: request and reply IDs don't match: %s %s", 
					mismatch_fmt_info(cur_session[hdr$pid,hdr$mid]), mismatch_fmt_hdr(hdr,cmd));
				delete cur_session[hdr$pid,hdr$mid];
				}
			else
				{
				info$rep_first_time = hdr$first_time;
				info$rep_last_time = hdr$last_time;
				info$rep_body_len = body_length;
				info$done = T;
				if (hdr$command !in more_specific_cmds)
					smb_log_cmd(c, info);
				}
			}
		}
	}

event smb_com_read_andx(c: connection, hdr: smb_hdr, fid: count, offset: count)
	{
	smb_set_fid_offset(c$id, hdr, fid, offset);
	}

event smb_com_read_andx_response(c: connection, hdr: smb_hdr, len: count) 
	{
	smb_set_file_payload(c$id, hdr, len);
	smb_log_cmd2(c, hdr);
	}

event smb_com_write_andx(c: connection, hdr: smb_hdr, fid: count, offset: count, len: count)
	{
	smb_set_fid_offset(c$id, hdr, fid, offset);
	smb_set_file_payload(c$id, hdr, len);
	}

event smb_com_write_andx_response(c: connection, hdr: smb_hdr)
	{
	smb_log_cmd2(c, hdr);
	}


event smb_com_nt_create_andx(c: connection, hdr: smb_hdr, name: string)
	{
	local cmdid = get_cmdid(c$id, hdr);	
	if (!cmdid)
		return;  # weird. Should not happen actually.
	# TODO: could/should check that there isn't a filename already there.
	smb_filenames[cmdid] = name;
	}

event smb_com_nt_create_andx_response(c: connection, hdr: smb_hdr, fid: count, size: count) 
	{
	# delete any old FID mappings. 
	delete_fid(c$id, fid);
	# this will implicitly create a new mapping
	smb_set_fid_offset(c$id, hdr, fid, 0);
	local cmdid = get_cmdid(c$id, hdr);	
	if (!cmdid)
		return;  # weird. Should not happen actually.
	if (cmdid !in smb_filenames)
		return;
	print smb_files_log, fmt("%.6f %s %d %s", network_time(), get_fid(c$id, fid), 
			size, smb_filenames[cmdid]);
	smb_log_cmd2(c, hdr);
	}


event smb_com_close(c: connection, hdr: smb_hdr, fid: count) 
	{
	# We first set to fid in the smb_cmd_info record, so it will be 
	# printed.
	smb_set_fid_offset(c$id, hdr, fid, 0);
	# Now we delete the fid mapping since the file has been closed.
	delete_fid(c$id, fid);
	}

event smb_error(c: connection, hdr: smb_hdr, cmd: count, cmd_str: string, errtype: count, error: count) 
	{
	print smb_log, fmt("ERROR: %s %s (0x%2x): %d %08x", id_string(c$id), cmd_str, cmd, errtype, error);
	}

event connection_state_remove(c: connection)
	{
	delete smb_sessions[c$id];
	delete fid_map[c$id];
	}

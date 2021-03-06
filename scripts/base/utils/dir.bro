@load base/utils/exec
@load base/frameworks/reporter
@load base/utils/paths

module Dir;

export {
	## The default interval this module checks for files in directories when
	## using the :bro:see:`Dir::monitor` function.
	const polling_interval = 30sec &redef;

	## Register a directory to monitor with a callback that is called
	## every time a previously unseen file is seen.  If a file is deleted
	## and seen to be gone, the file is available for being seen again in
	## the future.
	##
	## dir: The directory to monitor for files.
	##
	## callback: Callback that gets executed with each file name
	##           that is found.  Filenames are provided with the full path.
	##
	## poll_interval: An interval at which to check for new files.
	global monitor: function(dir: string, callback: function(fname: string),
	                         poll_interval: interval &default=polling_interval);
}

event Dir::monitor_ev(dir: string, last_files: set[string],
                      callback: function(fname: string),
                      poll_interval: interval)
	{
	when ( local result = Exec::run([$cmd=fmt("ls -i -1 \"%s/\"", str_shell_escape(dir))]) )
		{
		if ( result$exit_code != 0 )
			{
			Reporter::warning(fmt("Requested monitoring of non-existent directory (%s).", dir));
			return;
			}

		local current_files: set[string] = set();
		local files: vector of string = vector();

		if ( result?$stdout )
			files = result$stdout;

		for ( i in files )
			{
			local parts = split1(files[i], / /);
			if ( parts[1] !in last_files )
				callback(build_path_compressed(dir, parts[2]));
			add current_files[parts[1]];
			}

		schedule poll_interval
			{
			Dir::monitor_ev(dir, current_files, callback, poll_interval)
			};
		}
	}

function monitor(dir: string, callback: function(fname: string),
                 poll_interval: interval &default=polling_interval)
	{
	event Dir::monitor_ev(dir, set(), callback, poll_interval);
	}



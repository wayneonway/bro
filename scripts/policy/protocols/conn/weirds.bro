##! This script handles core generated connection related "weird" events to 
##! push weird information about connections into the weird framework.
##! For live operational deployments, this can frequently cause load issues
##! due to large numbers of these events being passed between nodes.

@load base/frameworks/notice

module Weird;

export {
	redef enum Notice::Type += {
		## Possible evasion; usually just chud.
		Retransmission_Inconsistency,
		## Could mean packet drop; could also be chud.
		Ack_Above_Hole,
		## Data has sequence hole; perhaps due to filtering.
		Content_Gap,
	};
}

event conn_weird(name: string, c: connection, addl: string)
	{
	report_weird_conn(network_time(), name, id_string(c$id), addl, c);
	}

event flow_weird(name: string, src: addr, dst: addr)
	{
	report_weird_orig(network_time(), name, fmt("%s -> %s", src, dst), src);
	}

event net_weird(name: string)
	{
	report_weird(network_time(), name, "", F, "", WEIRD_UNSPECIFIED, F);
	}

event rexmit_inconsistency(c: connection, t1: string, t2: string)
	{
	if ( c$id !in did_inconsistency_msg )
		{
		NOTICE([$note=Retransmission_Inconsistency,
		        $conn=c,
		        $msg=fmt("%s rexmit inconsistency (%s) (%s)",
		                 id_string(c$id), t1, t2)]);
		add did_inconsistency_msg[c$id];
		}
	}

event ack_above_hole(c: connection)
	{
	NOTICE([$note=Ack_Above_Hole, $conn=c,
	        $msg=fmt("%s ack above a hole", id_string(c$id))]);
	}

event content_gap(c: connection, is_orig: bool, seq: count, length: count)
	{
	NOTICE([$note=Content_Gap, $conn=c,
	        $msg=fmt("%s content gap (%s %d/%d)%s",
	                 id_string(c$id), is_orig ? ">" : "<", seq, length,
	                 is_external_connection(c) ? " [external]" : "")]);
	}


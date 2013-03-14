#ifndef FILE_ANALYSIS_PENDINGFILE_H
#define FILE_ANALYSIS_PENDINGFILE_H

#include "Conn.h"

namespace file_analysis {

class PendingFile {
public:

	virtual ~PendingFile();

	virtual bool Retry() const = 0;

	bool IsStale() const;

protected:

	PendingFile(Connection* arg_conn, bool arg_is_orig);

	Connection* conn;
	bool is_orig;
	double creation_time;
};

class PendingDataInChunk : public PendingFile {
public:

	PendingDataInChunk(const u_char* arg_data, uint64 arg_len,
	                   uint64 arg_offset, Connection* arg_conn,
	                   bool arg_is_orig);

	virtual ~PendingDataInChunk();

	virtual bool Retry() const;

protected:

	const u_char* data;
	uint64 len;
	uint64 offset;
};

class PendingDataInStream : public PendingFile {
public:

	PendingDataInStream(const u_char* arg_data, uint64 arg_len,
	                    Connection* arg_conn, bool arg_is_orig);

	virtual ~PendingDataInStream();

	virtual bool Retry() const;

protected:

	const u_char* data;
	uint64 len;
};

class PendingGap : public PendingFile {
public:

	PendingGap(uint64 arg_offset, uint64 arg_len, Connection* arg_conn,
	           bool arg_is_orig);

	virtual bool Retry() const;

protected:

	uint64 offset;
	uint64 len;
};

class PendingEOF : public PendingFile {
public:

	PendingEOF(Connection* arg_conn, bool arg_is_orig);

	virtual bool Retry() const;
};

class PendingSize : public PendingFile {
public:

	PendingSize(uint64 arg_size, Connection* arg_conn, bool arg_is_orig);

	virtual bool Retry() const;

protected:

	uint64 size;
};

} // namespace file_analysis

#endif
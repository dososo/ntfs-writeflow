#include "../ntfs3g-Bridging-Header.h"
#include "lifecycle_faults.h"
void koio_trace_reset(void);
int koio_trace_writable_mounts(void);
int koio_trace_pwrites(void);
int koio_trace_reads(void);
int koio_trace_syncs(void);
void koio_trace_fail_sync(int enabled);

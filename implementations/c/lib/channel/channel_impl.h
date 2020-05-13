#ifndef CHANNEL_IMPL_H
#define CHANNEL_IMPL_H

#include <stdio.h>
#include "ockam/memory.h"
#include "memory/stdlib/stdlib.h"
#include "ockam/transport.h"

struct ockam_channel_t {
  ockam_reader_t* transport_reader;
  ockam_writer_t* transport_writer;
  ockam_reader_t* channel_reader;
  ockam_writer_t* channel_writer;
  ockam_memory_t* memory;
};

#endif
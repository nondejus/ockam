#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include "ockam/syslog.h"
#include "ockam/memory.h"
#include "ockam/transport.h"
#include "ockam/io/io_impl.h"
#include "memory/stdlib/stdlib.h"
#include "ockam/channel.h"
#include "channel_impl.h"
#include "ockam/key_agreement.h"

ockam_error_t channel_read(void*, uint8_t*, size_t, size_t*);
ockam_error_t channel_write(void*, uint8_t*, size_t);

ockam_error_t ockam_channel_init(ockam_channel_t** pp_ch, ockam_channel_attributes_t* p_attrs)
{
  ockam_error_t error = OCKAM_ERROR_NONE;
  ockam_channel_t* p_ch = NULL;

  if ((NULL == pp_ch) || (NULL == p_attrs) ||
    (NULL == p_attrs->reader) || (NULL == p_attrs->writer) || (NULL == p_attrs->memory)) {
    error = CHANNEL_ERROR_PARAMS;
    goto exit;
  }

  error = ockam_memory_alloc_zeroed(p_attrs->memory, (uint8_t **)&p_ch, sizeof(ockam_channel_t));
  if (error) goto exit;

  printf("in ockam_channel_init\n");

  p_ch->memory = p_attrs->memory;
  p_ch->transport_reader = p_attrs->reader;
  p_ch->transport_writer = p_attrs->writer;

  *pp_ch = p_ch;

exit:
  if (error) {
    log_error(error, __func__ );
    if (p_ch) ockam_memory_free(p_ch->memory, (uint8_t *)p_ch, sizeof(ockam_channel_t));
  }
  return 0;
}

ockam_error_t ockam_channel_connect(ockam_channel_t* p_ch, ockam_reader_t** p_reader, ockam_writer_t** p_writer)
{
  ockam_error_t error = 0;
  printf("In ockam_channel_connect\n");
//  error = ockam_key_initiate(p_ch->key, p_ch->transport_writer);
  error = ockam_memory_alloc_zeroed(p_ch->memory, (uint8_t**)&p_ch->channel_reader, sizeof(ockam_reader_t));
  if (error) goto exit;
  p_ch->channel_reader->read = channel_read;
  p_ch->channel_reader->ctx = p_ch;
  *p_reader = p_ch->channel_reader;

  error = ockam_memory_alloc_zeroed(p_ch->memory, (uint8_t**)&p_ch->channel_writer, sizeof(ockam_writer_t));
  if (error) goto exit;
  p_ch->channel_writer->write = channel_write;
  p_ch->channel_writer->ctx = p_ch;
  *p_writer = p_ch->channel_writer;

exit:
  if(error) {
    log_error(error, __func__ );
    if(p_ch->channel_reader) ockam_memory_free(p_ch->memory, (uint8_t*)p_ch->channel_reader, sizeof(ockam_reader_t));
  }
  return error;
}

ockam_error_t ockam_channel_accept(ockam_channel_t* p_ch, ockam_reader_t** p_reader, ockam_writer_t** p_writer)
{
  ockam_error_t error = 0;
  printf("In ockam_channel_accept\n");
//  error = ockam_key_respond(p_ch->key, p_ch->transport_reader);
  error = ockam_memory_alloc_zeroed(p_ch->memory, (uint8_t**)&p_ch->channel_reader, sizeof(ockam_reader_t));
  if (error) goto exit;
  p_ch->channel_reader->read = channel_read;
  p_ch->channel_reader->ctx = p_ch;
  *p_reader = p_ch->channel_reader;

  error = ockam_memory_alloc_zeroed(p_ch->memory, (uint8_t**)&p_ch->channel_writer, sizeof(ockam_writer_t));
  if (error) goto exit;
  p_ch->channel_writer->write = channel_write;
  p_ch->channel_writer->ctx = p_ch;
  *p_writer = p_ch->channel_writer;

exit:
  if(error) {
    log_error(error, __func__ );
    if(p_ch->channel_reader) ockam_memory_free(p_ch->memory, (uint8_t*)p_ch->channel_reader, sizeof(ockam_reader_t));
  }
  return error;
}

ockam_error_t channel_read(void* ctx, uint8_t* buffer, size_t buffer_size, size_t* buffer_length)
{
  ockam_error_t error = 0;

  ockam_channel_t* p_ch = (ockam_channel_t*)ctx;
  printf("In channel_read\n");
  error = ockam_read(p_ch->transport_reader, buffer, buffer_size, buffer_length);
  if(error) goto exit;
//  error = ockam_key_decrypt(p_ch->key, transport_buff, transport_length, buffer, buffer_size, buffer_length);
exit:
  if(error) log_error(error, __func__ );
  return error;
}

ockam_error_t channel_write(void* ctx, uint8_t* buffer, size_t buffer_length)
{
  ockam_error_t error = 0;
  uint8_t transport_buff[80];
  size_t transport_length;
  ockam_channel_t* p_ch = (ockam_channel_t*)ctx;
  printf("In channel_write\n");
//  error = ockam_key_encrypt(p_ch->key, buffer, buffer_length, transport_buff, 80, &transport_length);
  error = ockam_write(p_ch->transport_writer, buffer, buffer_length);
exit:
  if(error) log_error(error, __func__ );
  return error;
}

ockam_error_t ockam_channel_deinit(ockam_channel_t* p_ch) {
  printf("in channel_io_deinit\n");
  ockam_memory_free(p_ch->memory, (uint8_t*)p_ch->channel_reader, sizeof(ockam_reader_t));
  ockam_memory_free(p_ch->memory, (uint8_t*)p_ch->channel_writer, sizeof(ockam_writer_t));
  free(p_ch);
  return 0;
}

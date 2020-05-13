#include <stdlib.h>
#include "ockam/channel.h"
#include "ockam/vault.h"

#define ACK      "ACK"
#define ACK_SIZE 3
#define OK       "OK"
#define OK_SIZE  2

#define MAX_TRANSMIT_SIZE 2048

ockam_error_t channel_initiator(ockam_vault_t* vault, ockam_memory_t* memory, ockam_ip_address_t* ip_address);
ockam_error_t channel_responder(ockam_vault_t* vault, ockam_memory_t* p_memory, ockam_ip_address_t* ip_address);
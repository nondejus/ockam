#include "ockam/error.h"

#include "ockam/memory.h"
#include "ockam/memory/stdlib.h"

#include "ockam/vault.h"
#include "ockam/vault/default.h"

#include <stdio.h>
#include <string.h>

/*
 * This example shows how to calculate sha256 digest.
 *
 * Ockam protocols depend on a variety of standard cryptographic primitives
 * or building blocks. Depending on the environment, these building blocks may
 * be provided by a software implementation or a cryptographically capable
 * hardware component.
 *
 * In order to support a variety of cryptographically capable hardware, we
 * maintain loose coupling between a protocol and how a specific building block
 * is invoked in a specific hardware. This is achieved using the abstract vault
 * interface (defined in `ockam/vault.h`).
 *
 * The default vault is a software-only implementation of the vault interface,
 * which may be used when a particular cryptographic building block is not
 * available in hardware.
 *
 * This example shows how to initialize a handle to the default software vault
 * and use it to generate random bytes with a vault.
 */
int main(void)
{
  int exit_code = 0;

  /*
   * All ockam functions return `ockam_error_t`. A function was successful
   * if the return value, `error == OCKAM_ERROR_NONE`
   *
   * This variable is used below to store and check function return values.
   */
  ockam_error_t error;

  /*
   * Before we can initialize a handle to the default vault, we must first
   * initialize a handle to an implementation of the memory interface, which
   * is defined in `ockam/memory.h`.
   *
   * The default vault requires a memory implementation handle at
   * initialization. This approach allows us to plugin the strategy for where
   * and how a vault should allocate memory.
   *
   * We may provide a memory implementation that allocates using
   * stdlib (malloc, free ...) or we may instead provide a an implementation
   * that allocates from a fixed sized buffer.
   *
   * In this example we use the stdlib implementation of the memory interface.
   */

  ockam_memory_t memory;

  error = ockam_memory_stdlib_init(&memory);
  if (error != OCKAM_ERROR_NONE) { goto exit; }

  /*
   * To initialize a handle to the default vault, we define a variable of the
   * generic type `ockam_vault_t` that will hold a handle to our vault.
   *
   * We also set the initialization attributes in a struct of
   * type `ockam_vault_default_attributes_t`
   *
   * We then pass the address of both these variable to the default
   * implementation specific initialization function.
   */

  ockam_vault_t                    vault;
  ockam_vault_default_attributes_t vault_attributes = { .memory = &memory };

  error = ockam_vault_default_init(&vault, &vault_attributes);
  if (error != OCKAM_ERROR_NONE) { goto exit; }

  /*
   * We now have an initialized vault handle of type ockam_vault_t, we can
   * call any of the functions defined in `ockam/vault.h` using this handle.
   */

  char*  input        = "hello world";
  size_t input_length = strlen(input);

  const size_t digest_size         = OCKAM_VAULT_SHA256_DIGEST_LENGTH;
  uint8_t      digest[digest_size] = { 0 };
  size_t       digest_length;

  error = ockam_vault_sha256(&vault, (uint8_t*) input, input_length, &digest[0], digest_size, &digest_length);
  if (error != OCKAM_ERROR_NONE) { goto exit; }

  /* Now let's print the digest in hexadecimal form. */

  int i;
  for (i = 0; i < digest_size; i++) { printf("%02x", digest[i]); }
  printf("\n");

  /* Deinitialize to free resources associated with this handle. */
  error = ockam_vault_deinit(&vault);
  if (error != OCKAM_ERROR_NONE) { goto exit; }

  /* Deinitialize to free resources associated with this handle. */
  error = ockam_memory_deinit(&memory);
  if (error != OCKAM_ERROR_NONE) { goto exit; }

exit:
  if (error != OCKAM_ERROR_NONE) { exit_code = -1; }
  return exit_code;
}


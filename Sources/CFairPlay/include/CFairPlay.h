#ifndef CFAIRPLAY_H
#define CFAIRPLAY_H

#include <stddef.h>
#include <stdint.h>

/* fp-setup step 1: 16-byte request -> 142-byte reply. Returns 0 on success. */
int fairplay_reply_setup(const uint8_t *request, size_t request_len, uint8_t reply[142]);

/* fp-setup step 2: 164-byte request -> 32-byte reply. Returns 0 on success; rejects a mode
 * byte (offset 12) outside 0-3, which the decryption would otherwise use unchecked.
 * Keep the 164-byte request: it is the key message needed by fairplay_decrypt_key. */
int fairplay_reply_handshake(const uint8_t *request, size_t request_len, uint8_t reply[32]);

/* Decrypts the 72-byte "ekey" sent in the first SETUP into the 16-byte AES session key. */
int fairplay_decrypt_key(const uint8_t key_message[164], const uint8_t ekey[72], uint8_t aes_key[16]);

#endif

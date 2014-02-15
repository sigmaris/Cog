#ifndef _USF_H_
#define _USF_H_
#define _CRT_SECURE_NO_WARNINGS


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

typedef struct usf_state usf_state_t;

typedef struct usf_state_helper usf_state_helper_t;

#include "usf.h"
#include "cpu.h"
#include "memory.h"

#ifdef __cplusplus
extern "C" {
#endif

ssize_t get_usf_state_size();

void usf_clear(void * state);

void usf_set_compare(void * state, int enable);
void usf_set_fifo_full(void * state, int enable);

int usf_upload_section(void * state, const uint8_t * data, ssize_t size);

void usf_render(void * state, int16_t * buffer, ssize_t count, int32_t * sample_rate);

void usf_shutdown(void * state);

#ifdef __cplusplus
}
#endif

#endif
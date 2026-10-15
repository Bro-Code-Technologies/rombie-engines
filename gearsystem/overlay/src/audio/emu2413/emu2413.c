/*
 * Rombie's replacement for src/audio/emu2413/emu2413.c in Gearsystem 3.9.22. See emu2413.h for why.
 *
 * Copyright (C) 2026 Bro Code Technologies
 *
 * This program is free software: you can redistribute it and/or modify it under the terms of the GNU General
 * Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
 * implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include "emu2413.h"

#include <string.h>

/* Mitsutaka Okazaki's emu2413 (MIT), compiled into this file so the build's source list is unchanged. */
#include "okazaki/emu2413.c"

/*
 * Gearsystem asks for one sample every 72 Z80 cycles, the OPLL's native rate, whatever the Z80's clock.
 * emu2413 produces exactly one sample per OPLL_calc() when its output rate is its clock divided by 72, so
 * the rate is fixed here and no resampler is created.
 */
#define NATIVE_RATE 49716u

/*
 * Chip-level FM gain, so FM sits against the PSG where the Genesis Plus GX code's output did. Measured on a
 * generated ROM that plays one note, the same Gearsystem built with each chip file: emu2413's output came
 * out at half the level of the file it replaces (peak 0.0438 against 0.0876, RMS 0.0107 against 0.0215).
 */
#define FM_GAIN_NUM 2
#define FM_GAIN_DEN 1

static OPLL *opll = NULL;

/* Port 0xF2 bit 0: FM output enabled (Master System / Mark III FM adapter specific). */
static uint8_t fm_status = 0;

/*
 * Gearsystem's YM2413.cpp saves and loads the chip by copying a block of bytes it gets from
 * YM2413GetContextPtr() in and out of a save state, and expects the chip to carry on from what it wrote
 * there. emu2413's own state holds pointers into itself, so the block is a copy made when it is asked for,
 * and what was written into it is applied to the chip (with the pointers set again by OPLL_load_state)
 * before the chip is next used.
 */
typedef struct
{
  uint8_t address;
  uint8_t status;
  uint8_t reserved[2];
  uint8_t chip[sizeof(OPLL)];
} ContextBlock;

static ContextBlock context;
static int context_handed_out = 0;

static void apply_context(void)
{
  if (!context_handed_out)
    return;

  context_handed_out = 0;
  OPLL_load_state(opll, context.chip, (int)sizeof(OPLL));
  opll->adr = context.address;
  fm_status = context.status & 1;
}

void YM2413Init(void)
{
  if (opll)
    OPLL_delete(opll);

  opll = OPLL_new(NATIVE_RATE * 72u, NATIVE_RATE);
  OPLL_setChipType(opll, 0);
  fm_status = 0;
  context_handed_out = 0;
}

void YM2413ResetChip(void)
{
  apply_context();
  OPLL_reset(opll);
}

void YM2413Write(unsigned int a, unsigned int v)
{
  apply_context();

  if (!(a & 2))
  {
    /* Address port, then data port. */
    OPLL_writeIO(opll, a & 1, (uint8_t)v);
  }
  else
  {
    fm_status = v & 0x01;
  }
}

unsigned int YM2413Read(void)
{
  /* Bit 0 returns the latched FM enable status; bits 1 and 2 return zero. */
  return 0xF8 | fm_status;
}

int YM2413Update(void)
{
  int out;

  apply_context();

  /* The chip advances whether or not its output is enabled. */
  out = OPLL_calc(opll);

  return fm_status ? (out * FM_GAIN_NUM) / FM_GAIN_DEN : 0;
}

unsigned char *YM2413GetContextPtr(void)
{
  apply_context();

  context.address = (uint8_t)opll->adr;
  context.status = fm_status;
  OPLL_save_state(opll, context.chip);
  context_handed_out = 1;

  return (unsigned char *)&context;
}

unsigned int YM2413GetContextSize(void)
{
  return (unsigned int)sizeof(ContextBlock);
}

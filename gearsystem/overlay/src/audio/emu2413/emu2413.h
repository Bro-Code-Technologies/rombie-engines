/*
 * Rombie's replacement for src/audio/emu2413/emu2413.h in Gearsystem 3.9.22.
 *
 * Gearsystem's own file here is Genesis Plus GX's ym2413.c (Jarek Burczynski's YM2413 from MAME, modified by
 * Eke-Eke), and Genesis Plus GX releases its code under terms that include "may not be sold, nor may they be
 * used in a commercial product or activity". Rombie sells a tier of its player, so its build of Gearsystem
 * does not contain that file. This header and emu2413.c present the same functions that Gearsystem's
 * YM2413.cpp calls, over Mitsutaka Okazaki's emu2413 (MIT, in okazaki/), so YM2413.cpp is used unchanged.
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

#ifndef ROMBIE_GEARSYSTEM_YM2413_H
#define ROMBIE_GEARSYSTEM_YM2413_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * What Gearsystem's YM2413.cpp reaches in the chip's saved state: only the selected register, as the first
 * byte. The rest of the block YM2413GetContextPtr() returns is this build's own and opaque to Gearsystem,
 * which only copies it into and out of a save state.
 */
typedef struct
{
  uint8_t address;
} YM2413_OPLL;

extern void YM2413Init(void);
extern void YM2413ResetChip(void);
extern int YM2413Update(void);
extern void YM2413Write(unsigned int a, unsigned int v);
extern unsigned int YM2413Read(void);
extern unsigned char *YM2413GetContextPtr(void);
extern unsigned int YM2413GetContextSize(void);

#ifdef __cplusplus
}
#endif

#endif /* ROMBIE_GEARSYSTEM_YM2413_H */

//
//  HCDecoder.m
//  HighlyComplete
//
//  Created by Christopher Snowhill on 9/30/13.
//  Copyright 2013 __NoWork, Inc__. All rights reserved.
//

#import "HCDecoder.h"

#import "hebios.h"

#import <psflib/psflib.h>
#import <psflib/psf2fs.h>

#import <HighlyExperimental/psx.h>
#import <HighlyExperimental/bios.h>
#import <HighlyExperimental/iop.h>
#import <HighlyExperimental/r3000.h>

#import <HighlyTheoretical/sega.h>

#import <HighlyQuixotic/qsound.h>

#import <HighlyAdvanced/GBA.h>


@implementation HCDecoder

+ (void)initialize
{
    bios_set_image(hebios, HEBIOS_SIZE);
    psx_init();
    sega_init();
    qsound_init();
}

- (NSDictionary *)metadata
{
    return metadataList;
}

- (long)retrieveTotalFrames
{
    return (tagLengthMs + tagFadeMs) * (sampleRate / 100) / 10;
}

void * source_fopen(const char * path)
{
    NSString * urlString = [NSString stringWithUTF8String:path];
    NSURL * url = [NSURL URLWithString:[urlString stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    
	id audioSourceClass = NSClassFromString(@"AudioSource");
	id<CogSource> source = [audioSourceClass audioSourceForURL:url];
    
    if (![source open:url])
        return 0;
    
    if (![source seekable])
        return 0;
    
    return [source retain];
}

size_t source_fread(void * buffer, size_t size, size_t count, void * handle)
{
    id source = (id)handle;
    
    return [source read:buffer amount:(size * count)] / size;
}

int source_fseek(void * handle, int64_t offset, int whence)
{
    id source = (id)handle;
    
    return [source seek:(long)offset whence:whence] ? 0 : -1;
}

int source_fclose(void * handle)
{
    id source = (id)handle;
    
    [source release];
    
    return 0;
}

long source_ftell(void * handle)
{
    id source = (id)handle;
    
    return [source tell];
}

static psf_file_callbacks source_callbacks =
{
    "/|\\",
    source_fopen,
    source_fread,
    source_fseek,
    source_fclose,
    source_ftell
};

struct psf_info_meta_state
{
    NSMutableDictionary * info;
    
	bool utf8;
    
	int tag_length_ms;
	int tag_fade_ms;
    
    int volume_scale;
};

static int parse_time_crap(NSString * value)
{
    NSArray *components = [value componentsSeparatedByString:@":"];

    float totalSeconds = 0;
    float multiplier = 1000;
    bool first = YES;
    for (id component in [components reverseObjectEnumerator]) {
        if (first) {
            first = NO;
            totalSeconds += [component floatValue] * multiplier;
        } else {
            totalSeconds += [component integerValue] * multiplier;
        }
        multiplier *= 60;
    }
                
    return totalSeconds;
}

static int db_to_int(NSString * value)
{
    return pow(10.0, [value floatValue] / 20) * 4096;
}

static int scale_to_int(NSString * value)
{
    return [value floatValue] * 4096;
}

static int psf_info_meta(void * context, const char * name, const char * value)
{
	struct psf_info_meta_state * state = ( struct psf_info_meta_state * ) context;
    
    NSString * tag = [NSString stringWithUTF8String:name];
	NSString * taglc = [tag lowercaseString];
    NSString * svalue = [NSString stringWithUTF8String:value];
    
	if ([taglc isEqualToString:@"game"])
	{
        taglc = @"album";
	}
	else if ([taglc isEqualToString:@"date"])
	{
		taglc = @"year";
	}
    
	if ([taglc hasPrefix:@"replaygain_"])
	{
        if ([taglc isEqualToString:@"replaygain_album_gain"])
        {
            state->volume_scale = db_to_int(svalue);
        }
        else if (!state->volume_scale && [taglc isEqualToString:@"replaygain_track_gain"])
        {
            state->volume_scale = db_to_int(svalue);
        }
	}
    else if ([taglc isEqualToString:@"volume"])
    {
        if (!state->volume_scale)
            state->volume_scale = scale_to_int(svalue);
    }
	else if ([taglc isEqualToString:@"length"])
	{
        state->tag_length_ms = parse_time_crap(svalue);
	}
	else if ([taglc isEqualToString:@"fade"])
	{
        state->tag_fade_ms = parse_time_crap(svalue);
	}
	else if ([taglc isEqualToString:@"utf8"])
	{
		state->utf8 = true;
	}
	else if ([taglc hasPrefix:@"_lib"])
	{
	}
	else if ([taglc isEqualToString:@"_refresh"])
	{
	}
	else if ([taglc hasPrefix:@"_"])
	{
		return -1;
	}
	else if ([taglc isEqualToString:@"title"] ||
             [taglc isEqualToString:@"artist"] ||
             [taglc isEqualToString:@"album"] ||
             [taglc isEqualToString:@"year"] ||
             [taglc isEqualToString:@"genre"] ||
             [taglc isEqualToString:@"track"])
	{
		[state->info setObject:svalue forKey:taglc];
	}
    
	return 0;
}

struct psf1_load_state
{
	void * emu;
	bool first;
	unsigned refresh;
};

typedef struct {
	uint32_t pc0;
	uint32_t gp0;
	uint32_t t_addr;
	uint32_t t_size;
	uint32_t d_addr;
	uint32_t d_size;
	uint32_t b_addr;
	uint32_t b_size;
	uint32_t s_ptr;
	uint32_t s_size;
	uint32_t sp,fp,gp,ret,base;
} exec_header_t;

typedef struct {
	char key[8];
	uint32_t text;
	uint32_t data;
	exec_header_t exec;
	char title[60];
} psxexe_hdr_t;

static int psf1_info(void * context, const char * name, const char * value)
{
    struct psf1_load_state * state = ( struct psf1_load_state * ) context;
    
    NSString * sname = [[NSString stringWithUTF8String:name] lowercaseString];
    NSString * svalue = [NSString stringWithUTF8String:value];
    
	if ( !state->refresh && [sname isEqualToString:@"_refresh"] )
	{
		state->refresh = [svalue integerValue];
	}
    
	return 0;
}

unsigned get_be16( void const* p )
{
    return  (unsigned) ((unsigned char const*) p) [0] << 8 |
    (unsigned) ((unsigned char const*) p) [1];
}

unsigned get_le32( void const* p )
{
    return  (unsigned) ((unsigned char const*) p) [3] << 24 |
    (unsigned) ((unsigned char const*) p) [2] << 16 |
    (unsigned) ((unsigned char const*) p) [1] <<  8 |
    (unsigned) ((unsigned char const*) p) [0];
}

unsigned get_be32( void const* p )
{
    return  (unsigned) ((unsigned char const*) p) [0] << 24 |
    (unsigned) ((unsigned char const*) p) [1] << 16 |
    (unsigned) ((unsigned char const*) p) [2] <<  8 |
    (unsigned) ((unsigned char const*) p) [3];
}

void set_le32( void* p, unsigned n )
{
    ((unsigned char*) p) [0] = (unsigned char) n;
    ((unsigned char*) p) [1] = (unsigned char) (n >> 8);
    ((unsigned char*) p) [2] = (unsigned char) (n >> 16);
    ((unsigned char*) p) [3] = (unsigned char) (n >> 24);
}

int psf1_loader(void * context, const uint8_t * exe, size_t exe_size,
                const uint8_t * reserved, size_t reserved_size)
{
    struct psf1_load_state * state = ( struct psf1_load_state * ) context;
    
    psxexe_hdr_t *psx = (psxexe_hdr_t *) exe;
    
    if ( exe_size < 0x800 ) return -1;
    
    uint32_t addr = get_le32( &psx->exec.t_addr );
    uint32_t size = exe_size - 0x800;
    
    addr &= 0x1fffff;
    if ( ( addr < 0x10000 ) || ( size > 0x1f0000 ) || ( addr + size > 0x200000 ) ) return -1;
    
    void * pIOP = psx_get_iop_state( state->emu );
    iop_upload_to_ram( pIOP, addr, exe + 0x800, size );
    
    if ( !state->refresh )
    {
        if (!strncasecmp((const char *) exe + 113, "Japan", 5)) state->refresh = 60;
        else if (!strncasecmp((const char *) exe + 113, "Europe", 6)) state->refresh = 50;
        else if (!strncasecmp((const char *) exe + 113, "North America", 13)) state->refresh = 60;
    }
    
    if ( state->first )
    {
        void * pR3000 = iop_get_r3000_state( pIOP );
        r3000_setreg(pR3000, R3000_REG_PC, get_le32( &psx->exec.pc0 ) );
        r3000_setreg(pR3000, R3000_REG_GEN+29, get_le32( &psx->exec.s_ptr ) );
        state->first = false;
    }
    
    return 0;
}

static int EMU_CALL virtual_readfile(void *context, const char *path, int offset, char *buffer, int length)
{
	return psf2fs_virtual_readfile(context, path, offset, buffer, length);
}

struct sdsf_loader_state
{
    uint8_t * data;
    size_t data_size;
};

int sdsf_loader(void * context, const uint8_t * exe, size_t exe_size,
                const uint8_t * reserved, size_t reserved_size)
{
    if ( exe_size < 4 ) return -1;
    
    struct sdsf_loader_state * state = ( struct sdsf_loader_state * ) context;
    
    uint8_t * dst = state->data;
    
    if ( state->data_size < 4 ) {
        state->data = dst = ( uint8_t * ) malloc( exe_size );
        state->data_size = exe_size;
        memcpy( dst, exe, exe_size );
        return 0;
    }
    
    uint32_t dst_start = get_le32( dst );
    uint32_t src_start = get_le32( exe );
    dst_start &= 0x7fffff;
    src_start &= 0x7fffff;
    uint32_t dst_len = state->data_size - 4;
    uint32_t src_len = exe_size - 4;
    if ( dst_len > 0x800000 ) dst_len = 0x800000;
    if ( src_len > 0x800000 ) src_len = 0x800000;
    
    if ( src_start < dst_start )
    {
        uint32_t diff = dst_start - src_start;
        state->data_size = dst_len + 4 + diff;
        state->data = dst = ( uint8_t * ) realloc( dst, state->data_size );
        memmove( dst + 4 + diff, dst + 4, dst_len );
        memset( dst + 4, 0, diff );
        dst_len += diff;
        dst_start = src_start;
        set_le32( dst, dst_start );
    }
    if ( ( src_start + src_len ) > ( dst_start + dst_len ) )
    {
        uint32_t diff = ( src_start + src_len ) - ( dst_start + dst_len );
        state->data_size = dst_len + 4 + diff;
        state->data = dst = ( uint8_t * ) realloc( dst, state->data_size );
        memset( dst + 4 + dst_len, 0, diff );
    }
    
    memcpy( dst + 4 + ( src_start - dst_start ), exe + 4, src_len );
    
    return 0;
}

struct qsf_loader_state
{
    uint8_t * key;
    uint32_t key_size;
    
    uint8_t * z80_rom;
    uint32_t z80_size;
    
    uint8_t * sample_rom;
    uint32_t sample_size;
};

static int upload_section( struct qsf_loader_state * state, const char * section, uint32_t start,
                          const uint8_t * data, uint32_t size )
{
    uint8_t ** array = NULL;
    uint32_t * array_size = NULL;
    uint32_t max_size = 0x7fffffff;
    
    if ( !strcmp( section, "KEY" ) ) { array = &state->key; array_size = &state->key_size; max_size = 11; }
    else if ( !strcmp( section, "Z80" ) ) { array = &state->z80_rom; array_size = &state->z80_size; }
    else if ( !strcmp( section, "SMP" ) ) { array = &state->sample_rom; array_size = &state->sample_size; }
    else return -1;
    
    if ( ( start + size ) < start ) return -1;
    
    uint32_t new_size = start + size;
    uint32_t old_size = *array_size;
    if ( new_size > max_size ) return -1;
    
    if ( new_size > old_size ) {
        *array = ( uint8_t * ) realloc( *array, new_size );
        *array_size = new_size;
        memset( (*array) + old_size, 0, new_size - old_size );
    }
    
    memcpy( (*array) + start, data, size );
    
    return 0;
}

static int qsf_loader(void * context, const uint8_t * exe, size_t exe_size,
                      const uint8_t * reserved, size_t reserved_size)
{
    struct qsf_loader_state * state = ( struct qsf_loader_state * ) context;
    
    for (;;) {
        char s[4];
        if ( exe_size < 11 ) break;
        memcpy( s, exe, 3 ); exe += 3; exe_size -= 3;
        s [3] = 0;
        uint32_t dataofs  = get_le32( exe ); exe += 4; exe_size -= 4;
        uint32_t datasize = get_le32( exe ); exe += 4; exe_size -= 4;
        if ( datasize > exe_size )
            return -1;
        
        if ( upload_section( state, s, dataofs, exe, datasize ) < 0 )
            return -1;
        
        exe += datasize;
        exe_size -= datasize;
    }
    
    return 0;
}

struct gsf_loader_state
{
    int entry_set;
    uint32_t entry;
    uint8_t * data;
    size_t data_size;
};

int gsf_loader(void * context, const uint8_t * exe, size_t exe_size,
               const uint8_t * reserved, size_t reserved_size)
{
    if ( exe_size < 12 ) return -1;
    
    struct gsf_loader_state * state = ( struct gsf_loader_state * ) context;
    
    unsigned char *iptr;
    unsigned isize;
    unsigned char *xptr;
    unsigned xentry = get_le32(exe + 0);
    unsigned xsize = get_le32(exe + 8);
    unsigned xofs = get_le32(exe + 4) & 0x1ffffff;
    if ( xsize < exe_size - 12 ) return -1;
    if (!state->entry_set)
    {
        state->entry = xentry;
        state->entry_set = 1;
    }
    {
        iptr = state->data;
        isize = state->data_size;
        state->data = 0;
        state->data_size = 0;
    }
    if (!iptr)
    {
        unsigned rsize = xofs + xsize;
        {
            rsize -= 1;
            rsize |= rsize >> 1;
            rsize |= rsize >> 2;
            rsize |= rsize >> 4;
            rsize |= rsize >> 8;
            rsize |= rsize >> 16;
            rsize += 1;
        }
        iptr = (unsigned char *) malloc(rsize + 10);
        if (!iptr)
            return -1;
        memset(iptr, 0, rsize + 10);
        isize = rsize;
    }
    else if (isize < xofs + xsize)
    {
        unsigned rsize = xofs + xsize;
        {
            rsize -= 1;
            rsize |= rsize >> 1;
            rsize |= rsize >> 2;
            rsize |= rsize >> 4;
            rsize |= rsize >> 8;
            rsize |= rsize >> 16;
            rsize += 1;
        }
        xptr = (unsigned char *) realloc(iptr, xofs + rsize + 10);
        if (!xptr)
        {
            free(iptr);
            return -1;
        }
        iptr = xptr;
        isize = rsize;
    }
    memcpy(iptr + xofs, exe + 12, xsize);
    {
        state->data = iptr;
        state->data_size = isize;
    }
    return 0;
}

struct gsf_sound_out : public GBASoundOut
{
    uint8_t * buffer;
    size_t samples_written;
    size_t buffer_size;
    gsf_sound_out() : buffer( nil ), samples_written( 0 ), buffer_size( 0 ) { }
    virtual ~gsf_sound_out() { if ( buffer ) free( buffer ); }
    // Receives signed 16-bit stereo audio and a byte count
    virtual void write(const void * samples, unsigned bytes)
    {
        if ( bytes + samples_written > buffer_size )
        {
            size_t new_buffer_size = ( buffer_size + bytes + 2047 ) & ~2047;
            buffer = ( uint8_t * ) realloc( buffer, new_buffer_size );
            buffer_size = new_buffer_size;
        }
        memcpy( buffer + samples_written, samples, bytes );
        samples_written += bytes;
    }
};

- (BOOL)open:(id<CogSource>)source
{
	if (![source seekable]) {
		return NO;
	}
	
	currentSource = [source retain];
	
    struct psf_info_meta_state info;
    
    info.info = [NSMutableDictionary dictionary];
    info.utf8 = false;
    info.tag_length_ms = 0;
    info.tag_fade_ms = 0;
    info.volume_scale = 0;
    
    NSString * decodedUrl = [[[source url] absoluteString] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    type = psf_load( [decodedUrl UTF8String], &source_callbacks, 0, 0, 0, psf_info_meta, &info );
    
    if (type <= 0)
        return NO;
    
    emulatorCore = nil;
    emulatorExtra = nil;
    
    sampleRate = 44100;
    
    if ( type == 1 )
    {
        emulatorCore = ( uint8_t * ) malloc( psx_get_state_size( 1 ) );
        
        psx_clear_state( emulatorCore, 1 );
        
        struct psf1_load_state state;
        
        state.emu = emulatorCore;
        state.first = true;
        state.refresh = 0;
        
        if ( psf_load( [decodedUrl UTF8String], &source_callbacks, 1, psf1_loader, &state, psf1_info, &state ) <= 0 )
            return NO;
        
        if ( state.refresh )
            psx_set_refresh( emulatorCore, state.refresh );
    }
    else if ( type == 2 )
    {
        emulatorExtra = psf2fs_create();
        
        struct psf1_load_state state;
        
        state.refresh = 0;
        
        if ( psf_load( [decodedUrl UTF8String], &source_callbacks, 2, psf2fs_load_callback, emulatorExtra, psf1_info, &state ) <= 0 )
            return NO;
        
        emulatorCore = ( uint8_t * ) malloc( psx_get_state_size( 2 ) );
        
        psx_clear_state( emulatorCore, 2 );
        
        if ( state.refresh )
            psx_set_refresh( emulatorCore, state.refresh );
        
        psx_set_readfile( emulatorCore, virtual_readfile, emulatorExtra );
        
        sampleRate = 48000;
    }
    else if ( type == 0x11 || type == 0x12 )
    {
        struct sdsf_loader_state state;
        memset( &state, 0, sizeof(state) );
        
        if ( psf_load( [decodedUrl UTF8String], &source_callbacks, type, sdsf_loader, &state, 0, 0) <= 0 )
            return NO;
        
        emulatorCore = ( uint8_t * ) malloc( sega_get_state_size( type - 0x10 ) );
        
        sega_clear_state( emulatorCore, type - 0x10 );
        
        sega_enable_dry( emulatorCore, 1 );
        sega_enable_dsp( emulatorCore, 1 );
        
        sega_enable_dsp_dynarec( emulatorCore, 0 );
        
        uint32_t start  = *(uint32_t*) state.data;
        uint32_t length = state.data_size;
        const uint32_t max_length = ( type == 0x12 ) ? 0x800000 : 0x80000;
        if ( ( start + ( length - 4 ) ) > max_length ) {
            length = max_length - start + 4;
        }
        sega_upload_program( emulatorCore, state.data, length );
        
        free( state.data );
    }
    else if ( type == 0x22 )
    {
        struct gsf_loader_state state;
        memset( &state, 0, sizeof(state) );
        
        if ( psf_load( [decodedUrl UTF8String], &source_callbacks, 0x22, gsf_loader, &state, 0, 0 ) <= 0 )
            return NO;
        
        GBASystem * system = new GBASystem;
        
        emulatorCore = ( uint8_t * ) system;
        
        system->cpuIsMultiBoot = ((state.entry >> 24) == 2);
        
        CPULoadRom( system, state.data, state.data_size );
        
        free( state.data );
        
        struct gsf_sound_out * sound_out = new gsf_sound_out;
        
        emulatorExtra = sound_out;
        
        soundInit( system, sound_out );
        soundReset( system );
        
        CPUInit( system );
        CPUReset( system );
    }
    else if ( type == 0x41 )
    {
        struct qsf_loader_state * state = ( struct qsf_loader_state * ) calloc( 1, sizeof( *state ) );

        emulatorExtra = state;
        
        if ( psf_load( [decodedUrl UTF8String], &source_callbacks, 0x41, qsf_loader, state, 0, 0) <= 0 )
            return NO;
        
        emulatorCore = ( uint8_t * ) malloc( qsound_get_state_size() );
        
        qsound_clear_state( emulatorCore );
        
        if(state->key_size == 11) {
            uint8_t * ptr = state->key;
            uint32_t swap_key1 = get_be32( ptr +  0 );
            uint32_t swap_key2 = get_be32( ptr +  4 );
            uint32_t addr_key  = get_be16( ptr +  8 );
            uint8_t  xor_key   =        *( ptr + 10 );
            qsound_set_kabuki_key( emulatorCore, swap_key1, swap_key2, addr_key, xor_key );
        } else {
            qsound_set_kabuki_key( emulatorCore, 0, 0, 0, 0 );
        }
        qsound_set_z80_rom( emulatorCore, state->z80_rom, state->z80_size );
        qsound_set_sample_rom( emulatorCore, state->sample_rom, state->sample_size );
    }
    else return NO;

    tagLengthMs = info.tag_length_ms;
    tagFadeMs = info.tag_fade_ms;
    volumeScale = info.volume_scale;
    
    metadataList = info.info;
    
    framesRead = 0;
	totalFrames = [self retrieveTotalFrames];
	
	[self willChangeValueForKey:@"properties"];
	[self didChangeValueForKey:@"properties"];
	
	return YES;
}


- (int)readAudio:(void *)buf frames:(UInt32)frames
{
    if ( type == 1 || type == 2 )
    {
        uint32_t howmany = frames;
        psx_execute( emulatorCore, 0x7fffffff, ( int16_t * ) buf, &howmany, 0 );
        frames = howmany;
    }
    else if ( type == 0x11 || type == 0x12 )
    {
        uint32_t howmany = frames;
        sega_execute( emulatorCore, 0x7fffffff, ( int16_t * ) buf, &howmany );
        frames = howmany;
    }
    else if ( type == 0x22 )
    {
        GBASystem * system = ( GBASystem * ) emulatorCore;
        struct gsf_sound_out * sound_out = ( struct gsf_sound_out * ) emulatorExtra;

        if ( frames * 4 > sound_out->samples_written )
            CPULoop( system, 250000 );
        
        UInt32 frames_rendered = sound_out->samples_written / 4;
        
        if ( frames_rendered >= frames )
        {
            memcpy( buf, sound_out->buffer, frames * 4 );
            frames_rendered -= frames;
            memcpy( sound_out->buffer, sound_out->buffer + frames * 4, frames_rendered * 4 );
        }
        else
        {
            memcpy( buf, sound_out->buffer, frames_rendered * 4 );
            frames = frames_rendered;
            frames_rendered = 0;
        }
        sound_out->samples_written = frames_rendered;
    }
    else if ( type == 0x41 )
    {
        uint32_t howmany = frames;
        qsound_execute( emulatorCore, 0x7fffffff, ( int16_t * ) buf, &howmany);
        frames = howmany;
    }
    
    if ( volumeScale )
    {
        int16_t * samples = ( int16_t * ) buf;
        
        for ( UInt32 i = 0, j = frames * 2; i < j; ++i )
        {
            int sample = ( samples[ i ] * volumeScale ) >> 12;
            if ( (uint32_t)(sample + 0x8000) & 0xffff0000 ) sample = ( sample >> 31 ) ^ 0x7fff;
            samples[ i ] = ( int16_t ) sample;
        }
    }

	framesRead += frames;

	return frames;
}

- (void)close
{
    if ( emulatorCore ) {
        if ( type == 0x22 ) {
            GBASystem * system = ( GBASystem * ) emulatorCore;
            CPUCleanUp( system );
            soundShutdown( system );
            delete system;
        } else {
            free( emulatorCore );
        }
        emulatorCore = nil;
    }

    if ( type == 2 && emulatorExtra ) {
        psf2fs_delete( emulatorExtra );
        emulatorExtra = nil;
    } else if ( type == 0x22 && emulatorExtra ) {
        delete ( gsf_sound_out * ) emulatorExtra;
        emulatorExtra = nil;
    } else if ( type == 0x41 && emulatorExtra ) {
        struct qsf_loader_state * state = ( struct qsf_loader_state * ) emulatorExtra;
        free( state->key );
        free( state->z80_rom );
        free( state->sample_rom );
        free( state );
        emulatorExtra = nil;
    }
}

- (long)seek:(long)frame
{
    if (frame < framesRead) {
        [self close];
        [self open:currentSource];
    }
    
    if ( type == 1 || type == 2 )
    {
        uint32_t howmany = (uint32_t)(frame - framesRead);
        psx_execute( emulatorCore, 0x7fffffff, 0, &howmany, 0 );
        frame = (long)(howmany + framesRead);
    }
    else if ( type == 0x11 || type == 0x12 )
    {
        uint32_t howmany = (uint32_t)(frame - framesRead);
        sega_execute( emulatorCore, 0x7fffffff, 0, &howmany );
        frame = (long)(howmany + framesRead);
    }
    else if ( type == 0x22 )
    {
        GBASystem * system = ( GBASystem * ) emulatorCore;
        struct gsf_sound_out * sound_out = ( struct gsf_sound_out * ) emulatorExtra;

        long frames_to_run = frame - framesRead;

        do
        {
            if ( frames_to_run * 4 >= sound_out->samples_written )
            {
                frames_to_run -= sound_out->samples_written / 4;
                sound_out->samples_written = 0;
            }
            else
            {
                sound_out->samples_written -= frames_to_run * 4;
                memcpy( sound_out->buffer, sound_out->buffer + frames_to_run * 4, sound_out->samples_written );
                frames_to_run = 0;
            }
            
            if ( frames_to_run )
                CPULoop( system, 250000 );
        } while ( frames_to_run );
    }
    else if ( type == 0x41 )
    {
        uint32_t howmany = (uint32_t)(frame - framesRead);
        qsound_execute( emulatorCore, 0x7fffffff, 0, &howmany );
        frame = (long)(howmany + framesRead);
    }
    
	return frame;
}

- (NSDictionary *)properties
{
	return [NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithInt:2], @"channels",
			[NSNumber numberWithInt:16], @"bitsPerSample",
			[NSNumber numberWithFloat:sampleRate], @"sampleRate",
			[NSNumber numberWithInteger:totalFrames], @"totalFrames",
			[NSNumber numberWithInt:0], @"bitrate",
			[NSNumber numberWithBool:YES], @"seekable",
			@"host", @"endian",
			nil];
}

+ (NSDictionary *)metadataForURL:(NSURL *)url
{
    struct psf_info_meta_state info;
    
    info.info = [NSMutableDictionary dictionary];
    info.utf8 = false;
    info.tag_length_ms = 0;
    info.tag_fade_ms = 0;
    info.volume_scale = 0;
    
    NSString * decodedUrl = [[url absoluteString] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

    if ( psf_load( [decodedUrl UTF8String], &source_callbacks, 0, 0, 0, psf_info_meta, &info ) <= 0)
        return NO;
    
	return info.info;
}

+ (NSArray *)fileTypes
{
	return [NSArray arrayWithObjects:@"psf",@"minipsf",@"psf2", @"minipsf2", @"ssf", @"minissf", @"dsf", @"minidsf", @"qsf", @"miniqsf", @"gsf", @"minigsf", nil];
}

+ (NSArray *)mimeTypes
{
	return [NSArray arrayWithObjects:@"audio/x-psf", nil];
}



@end
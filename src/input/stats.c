/*****************************************************************************
 * stats.c: Statistics handling
 *****************************************************************************
 * Copyright (C) 2006 VLC authors and VideoLAN
 * $Id: d7ee85a6e1fbd9210a38ef75237b57cd3d807a65 $
 *
 * Authors: Clément Stenac <zorglub@videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/
 
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif
 
#include <vlc_common.h>
#include "input/input_internal.h"
 
//JULIANO
//#define  STREAM_LOG "/home/cloud/stream_log"
#include <sys/time.h>
#include <stdio.h>
 
/**
 * Create a statistics counter
 * \param i_compute_type the aggregation type. One of STATS_LAST (always
 * keep the last value), STATS_COUNTER (increment by the passed value),
 * STATS_MAX (keep the maximum passed value), STATS_MIN, or STATS_DERIVATIVE
 * (keep a time derivative of the value)
 */
counter_t * stats_CounterCreate( int i_compute_type )
{
    counter_t *p_counter = (counter_t*) malloc( sizeof( counter_t ) ) ;
 
    if( !p_counter ) return NULL;
    p_counter->i_compute_type = i_compute_type;
    p_counter->i_samples = 0;
    p_counter->pp_samples = NULL;
 
    p_counter->last_update = 0;
 
    return p_counter;
}
 
static inline int64_t stats_GetTotal(const counter_t *counter)
{
    if (counter == NULL || counter->i_samples == 0)
        return 0;
    return counter->pp_samples[0]->value;
}
 
static inline float stats_GetRate(const counter_t *counter)
{
    if (counter == NULL || counter->i_samples < 2)
        return 0.;
 
    return (counter->pp_samples[0]->value - counter->pp_samples[1]->value)
        / (float)(counter->pp_samples[0]->date - counter->pp_samples[1]->date);
}
 
input_stats_t *stats_NewInputStats( input_thread_t *p_input )
{
    (void)p_input;
    input_stats_t *p_stats = calloc( 1, sizeof(input_stats_t) );
    if( !p_stats )
        return NULL;
 
    vlc_mutex_init( &p_stats->lock );
    stats_ReinitInputStats( p_stats );
 
    return p_stats;
}
 
// JULIANO
static time_t time_aux = 0;
static bool firstRun = true;

static int audioTime = 0;
static int stopStats = 0;

static long int displayed_pictures_aux = 0;
static long int played_abuffers_aux = 0;
static long int decoded_video_aux = 0;
static long int decoded_audio_aux = 0;

static long int displayed_pictures_calc = 0;
static long int played_abuffers_calc = 0;
static long int decoded_video_calc = 0;
static long int decoded_audio_calc = 0;

static char fileName[50];
 
void stats_ComputeInputStats(input_thread_t *input, input_stats_t *st)
{
    input_thread_private_t *priv = input_priv(input);
    double sendBitrate = 0;
 
 
    if (!libvlc_stats(input))
        return;
 
    vlc_mutex_lock(&priv->counters.counters_lock);
    vlc_mutex_lock(&st->lock);
 
    /* Input */
    st->i_read_packets = stats_GetTotal(priv->counters.p_read_packets);
    st->i_read_bytes = stats_GetTotal(priv->counters.p_read_bytes);
    st->f_input_bitrate = stats_GetRate(priv->counters.p_input_bitrate);
    st->i_demux_read_bytes = stats_GetTotal(priv->counters.p_demux_read);
    st->f_demux_bitrate = stats_GetRate(priv->counters.p_demux_bitrate);
    st->i_demux_corrupted = stats_GetTotal(priv->counters.p_demux_corrupted);
    st->i_demux_discontinuity = stats_GetTotal(priv->counters.p_demux_discontinuity);
 
    /* Decoders */
    st->i_decoded_video = stats_GetTotal(priv->counters.p_decoded_video);
    st->i_decoded_audio = stats_GetTotal(priv->counters.p_decoded_audio);
 
    /* Sout */
    if (priv->counters.p_sout_send_bitrate)
    {
        st->i_sent_packets = stats_GetTotal(priv->counters.p_sout_sent_packets);
        st->i_sent_bytes = stats_GetTotal(priv->counters.p_sout_sent_bytes);
        st->f_send_bitrate = stats_GetRate(priv->counters.p_sout_send_bitrate);
        sendBitrate = st->f_send_bitrate;
    }
 
    /* Aout */
    st->i_played_abuffers = stats_GetTotal(priv->counters.p_played_abuffers);
    st->i_lost_abuffers = stats_GetTotal(priv->counters.p_lost_abuffers);
 
    /* Vouts */
    st->i_displayed_pictures = stats_GetTotal(priv->counters.p_displayed_pictures);
    st->i_lost_pictures = stats_GetTotal(priv->counters.p_lost_pictures);
 
    // JULIANO
    //FILE *fp = fopen(STREAM_LOG);
    struct timeval tv;
    gettimeofday(&tv, NULL);

    if(time_aux < tv.tv_sec
        //&& audioTime < 2
        //&& st->i_displayed_pictures > 0      // disregard first time this if() runs
        && !firstRun
        //&& stopStats != st->i_decoded_audio
        ) {
 
        audioTime++;
        //if(audioTime == 2) {
            FILE *fp = fopen(fileName, "a+");
             
            if((st->i_displayed_pictures - displayed_pictures_aux) >= 0) {
                fprintf(fp, "%li,%.0f,%.0f,%li,%li,%.0f,%li,%li,%li,"
                            "%li,%li,%li,%li,%li,%li,%li,%li,%li\n",
                            tv.tv_sec, //tv.tv_usec,
                            st->f_input_bitrate,
                            st->f_demux_bitrate,
                            st->i_demux_corrupted,
                            st->i_demux_discontinuity,
                            sendBitrate,
                            st->i_displayed_pictures,// - displayed_pictures_aux,
                            st->i_played_abuffers,// - played_abuffers_aux,
                            st->i_decoded_video,// - decoded_video_aux,
                            st->i_decoded_audio,// - decoded_audio_aux
 
                            displayed_pictures_aux,
                            played_abuffers_aux,
                            decoded_video_aux,
                            decoded_audio_aux,
 
                            st->i_displayed_pictures - displayed_pictures_aux,
                            st->i_played_abuffers - played_abuffers_aux,
                            st->i_decoded_video - decoded_video_aux,
                            st->i_decoded_audio - decoded_audio_aux
                            );

		displayed_pictures_calc = st->i_displayed_pictures - displayed_pictures_aux;
		played_abuffers_calc = st->i_played_abuffers - played_abuffers_aux;
		decoded_video_calc = st->i_decoded_video - decoded_video_aux;
		decoded_audio_calc = st->i_decoded_audio - decoded_audio_aux;
            }
            // if framesDisplayedCalc is lower than last seconds, display last seconds framerate instead of zero
            else //if ((st->i_displayed_pictures - displayed_pictures_aux) < 0)
		{
                fprintf(fp, "%li,%.0f,%.0f,%li,%li,%.0f,%li,%li,%li"
                            ",%li,%li,%li,%li,%li,%li,%li,%li,%li\n",
                            tv.tv_sec, //tv.tv_usec,
                            st->f_input_bitrate,
                            st->f_demux_bitrate,
                            st->i_demux_corrupted,
                            st->i_demux_discontinuity,
                            sendBitrate,
                            displayed_pictures_aux,
                            played_abuffers_aux,
                            decoded_video_aux,
                            decoded_audio_aux,
 
                            displayed_pictures_aux,
                            played_abuffers_aux,
                            decoded_video_aux,
                            decoded_audio_aux,
 
                            displayed_pictures_calc,
                            played_abuffers_calc,
                            decoded_video_calc,
                            decoded_audio_calc
                          );
            }
            /*else{
                fprintf(fp, "%li,%.0f,%.0f,%li,%li,%.0f,%li,%li,%li"
                            ",%li,%li,%li,%li,%li,%li,%li,%li,%li\n",
                            tv.tv_sec);
            }*/
            fflush(fp);
            fclose(fp);
            stopStats = st->i_decoded_audio;
            time_aux = tv.tv_sec;
            audioTime = 0;
 
            displayed_pictures_aux = st->i_displayed_pictures;
            played_abuffers_aux = st->i_played_abuffers;
            decoded_video_aux = st->i_decoded_video;
            decoded_audio_aux = st->i_decoded_audio;

           // displayed_pictures_calc = st->i_displayed_pictures - displayed_pictures_aux;
           // played_abuffers_calc = st->i_played_abuffers - played_abuffers_aux;
           // decoded_video_calc = st->i_decoded_video - decoded_video_aux;
           // decoded_audio_calc = st->i_decoded_audio - decoded_audio_aux;

        //}
    }
    /*else {
        time_aux = tv.tv_sec;
        audioTime = 0;
    }*/
     
    if(firstRun) {
    time_t currdate;
    time(&currdate);
 
    struct tm* datetime;
    datetime = localtime(&currdate);
 
    strftime(fileName, 50, "/home/cloud/logs/dash_exp_%Y%m%d%H%M%S.log", datetime);
        FILE *fp = fopen(fileName, "a+");
        if (NULL != fp) {
            fseek (fp, 0, SEEK_END);
            long int size = ftell(fp);
 
            audioTime++;
            if (0 == size 
                    //&& audioTime == 2
                        ) {
                fprintf(fp, "\"timestamp\",\"inputBitrate\",\"demuxBitrate\",\"demuxCorrupted\",\"demuxDiscontinuity\","
                    "\"sendBitrate\",\"framesDisplayed\",\"playedAudioBuffers\",\"decodedVideo\",\"decodedAudio\","
                    "\"framesDisplayedAux\",\"playedAudioBuffersAux\",\"decodedVideoAux\",\"decodedAudioAux\","
                    "\"framesDisplayedCalc\",\"playedAudioBuffersCalc\",\"decodedVideoCalc\",\"decodedAudioCalc\"\n");
             
                /*fprintf(fp, ",T_STATS:%li"
                            ",%.0f"
                            ",%.0f"
                            ",%li"
                            ",%li"
                            ",%.0f"
                            " -- "
                            ",%li"
                            ",%li"
                            ",%li"
                            ",%li"
                            " -- "
                            ",%li"
                            ",%li"
                            ",%li"
                            ",%li",
                            tv.tv_sec,
                            st->f_input_bitrate,
                            st->f_demux_bitrate,
                            st->i_demux_corrupted,
                            st->i_demux_discontinuity,
                            sendBitrate,
                            st->i_displayed_pictures,// - displayed_pictures_aux,
                            st->i_played_abuffers,// - played_abuffers_aux,
                            st->i_decoded_video,// - decoded_video_aux,
                            st->i_decoded_audio,// - decoded_audio_aux
 
                            displayed_pictures_aux,
                            played_abuffers_aux,
                            decoded_video_aux,
                            decoded_audio_aux
                        );
                audioTime = 0;*/
                //fflush(fp);
            }
        }
        fclose(fp);
        firstRun = false;
    }
 
    if(firstRun)
        firstRun = false;
 
    vlc_mutex_unlock(&st->lock);
    vlc_mutex_unlock(&priv->counters.counters_lock);
}
 
void stats_ReinitInputStats( input_stats_t *p_stats )
{
    vlc_mutex_lock( &p_stats->lock );
    p_stats->i_read_packets = p_stats->i_read_bytes =
    p_stats->f_input_bitrate = p_stats->f_average_input_bitrate =
    p_stats->i_demux_read_packets = p_stats->i_demux_read_bytes =
    p_stats->f_demux_bitrate = p_stats->f_average_demux_bitrate =
    p_stats->i_demux_corrupted = p_stats->i_demux_discontinuity =
    p_stats->i_displayed_pictures = p_stats->i_lost_pictures =
    p_stats->i_played_abuffers = p_stats->i_lost_abuffers =
    p_stats->i_decoded_video = p_stats->i_decoded_audio =
    p_stats->i_sent_bytes = p_stats->i_sent_packets = p_stats->f_send_bitrate
     = 0;
    vlc_mutex_unlock( &p_stats->lock );
}
 
void stats_CounterClean( counter_t *p_c )
{
    if( p_c )
    {
        for( int i = 0; i < p_c->i_samples; i++ )
            free( p_c->pp_samples[i] );
        TAB_CLEAN(p_c->i_samples, p_c->pp_samples);
        free( p_c );
    }
}
 
 
/** Update a counter element with new values
 * \param p_counter the counter to update
 * \param val the vlc_value union containing the new value to aggregate. For
 * more information on how data is aggregated, \see stats_Create
 * \param val_new a pointer that will be filled with new data
 */
void stats_Update( counter_t *p_counter, uint64_t val, uint64_t *new_val )
{
    if( !p_counter )
        return;
 
    switch( p_counter->i_compute_type )
    {
    case STATS_DERIVATIVE:
    {
        counter_sample_t *p_new, *p_old;
        mtime_t now = mdate();
        if( now - p_counter->last_update < CLOCK_FREQ )
            return;
        p_counter->last_update = now;
        /* Insert the new one at the beginning */
        p_new = (counter_sample_t*)malloc( sizeof( counter_sample_t ) );
        if (unlikely(p_new == NULL))
            return; /* NOTE: Losing sample here */
 
        p_new->value = val;
        p_new->date = p_counter->last_update;
        TAB_INSERT(p_counter->i_samples, p_counter->pp_samples, p_new, 0);
 
        if( p_counter->i_samples == 3 )
        {
            p_old = p_counter->pp_samples[2];
            TAB_ERASE(p_counter->i_samples, p_counter->pp_samples, 2);
            free( p_old );
        }
        break;
    }
    case STATS_COUNTER:
        if( p_counter->i_samples == 0 )
        {
            counter_sample_t *p_new = (counter_sample_t*)malloc(
                                               sizeof( counter_sample_t ) );
            if (unlikely(p_new == NULL))
                return; /* NOTE: Losing sample here */
 
            p_new->value = 0;
 
            TAB_APPEND(p_counter->i_samples, p_counter->pp_samples, p_new);
        }
        if( p_counter->i_samples == 1 )
        {
            p_counter->pp_samples[0]->value += val;
            if( new_val )
                *new_val = p_counter->pp_samples[0]->value;
        }
        break;
    }
}

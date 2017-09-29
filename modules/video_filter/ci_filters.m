/*****************************************************************************
 * ci_filters.m: Video filters for MacOSX OpenGL video output
 *****************************************************************************
 * Copyright © 2017 VLC authors, VideoLAN and VideoLabs
 *
 * Author: Victorien Le Couviour--Tuffet <victorien.lecouviour.tuffet@gmail.com>
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

#include <assert.h>

#include <vlc_common.h>
#include <vlc_atomic.h>
#include <vlc_filter.h>
#include <vlc_picture.h>
#include <vlc_plugin.h>
#include <vlc_modules.h>
#include <vlc_mouse.h>
#include "filter_picture.h"
#include "vt_utils.h"

#include <CoreImage/CIContext.h>
#include <CoreImage/CIImage.h>
#include <CoreImage/CIFilter.h>
#include <CoreImage/CIVector.h>

enum    filter_type
{
    FILTER_NONE = -1,
    FILTER_ADJUST_HUE,
    FILTER_ADJUST_COLOR_CONTROLS,
    FILTER_ADJUST_GAMMA,
    FILTER_INVERT,
    FILTER_POSTERIZE,
    FILTER_SEPIA,
    FILTER_SHARPEN,
    NUM_FILTERS,
    NUM_MAX_EQUIVALENT_VLC_FILTERS = 3
};

#define NUM_FILTER_PARAM_MAX    4

struct  filter_chain
{
    enum filter_type            filter;
    CIFilter *                  ci_filter;
    vlc_atomic_float            ci_params[NUM_FILTER_PARAM_MAX];
    struct filter_chain *       next;
};

struct  ci_filters_ctx
{
    CVPixelBufferPoolRef        cvpx_pool;
    video_format_t              cvpx_pool_fmt;
    CVPixelBufferPoolRef        outconv_cvpx_pool;
    CIContext *                 ci_ctx;
    CGColorSpaceRef             color_space;
    struct filter_chain *       fchain;
    filter_t *                  dst_converter;
};

struct filter_sys_t
{
    char const *                psz_filter;
    bool                        mouse_moved;
    vlc_mouse_t                 old_mouse;
    vlc_mouse_t                 mouse;
    struct ci_filters_ctx *     ctx;
};

struct  range
{
    float       min;
    float       max;
};

struct  filter_desc
{
    struct
    {
        char const *            vlc;
        NSString *              ci;
    } const             name_desc;

    struct      filter_param_desc
    {
        char const *            vlc;
        NSString *              ci;
        struct
        {
            struct range    vlc;
            struct range    ci;
        }                       ranges[2];
        int                     vlc_type;
    } const             param_descs[NUM_FILTER_PARAM_MAX];
    void (*pf_init)(filter_t *filter, struct filter_chain *fchain);
    void (*pf_control)(filter_t *filter, struct filter_chain *fchain);
};

static struct filter_desc       filter_desc_table[] =
{
    [FILTER_ADJUST_HUE] =
    {
        { "adjust", @"CIHueAdjust" },
        {
            { "hue", @"inputAngle", {{{-180.f, +180.f}, {+3.f, -3.f}}}, VLC_VAR_FLOAT }
        }
    },
    [FILTER_ADJUST_COLOR_CONTROLS] =
    {
        { "adjust", @"CIColorControls" },
        {
            { "contrast",   @"inputContrast",   {{{.0f, 2.f}, {.0f, 2.f}}},   VLC_VAR_FLOAT },
            { "brightness", @"inputBrightness", {{{.0f, 2.f}, {-1.f, +1.f}}}, VLC_VAR_FLOAT },
            { "saturation", @"inputSaturation", {{{.0f, 3.f}, {.0f, 2.7f}}},  VLC_VAR_FLOAT }
        }
    },
    [FILTER_ADJUST_GAMMA] =
    {
        { "adjust", @"CIGammaAdjust" },
        {
            { "gamma", @"inputPower", {{{.01f, 1.f}, {10.f, 1.f}}, {{1.f, 10.f}, {1.f, .01f}}}, VLC_VAR_FLOAT }
        }
    },
    [FILTER_INVERT] =
    {
        { "invert", @"CIColorInvert" }
    },
    [FILTER_POSTERIZE] =
    {
        { "posterize", @"CIColorPosterize" },
        {
            { "posterize-level", @"inputLevels", {{{2.f, 256.f}, {2.f, 256.f}}}, VLC_VAR_INTEGER }
        }
    },
    [FILTER_SEPIA] =
    {
        { "sepia", @"CISepiaTone" },
        {
            { "sepia-intensity", @"inputIntensity", {{{.0f, 255.f}, {.0f, 1.f}}}, VLC_VAR_INTEGER }
        }
    },
    [FILTER_SHARPEN] =
    {
        { "sharpen", @"CISharpenLuminance" },
        {
            { "sharpen-sigma", @"inputSharpness", {{{.0f, 2.f}, {.0f, 5.f}}}, VLC_VAR_FLOAT }
        }
    }
};

#define GET_CI_VALUE(vlc_value, vlc_range, ci_range)               \
    ((vlc_value - vlc_range.min) * (ci_range.max - ci_range.min) / \
     (vlc_range.max - vlc_range.min) + ci_range.min)

static struct filter_chain *
filter_chain_AddFilter(struct filter_chain **fchain, enum filter_type filter)
{
    struct filter_chain *elem = calloc(1, sizeof(*elem));
    if (!elem)
        return NULL;
    elem->filter = filter;

    if (!*fchain)
        *fchain = elem;
    else
    {
        struct filter_chain *it = *fchain;
        while (it->next) it = it->next;
        it->next = elem;
    }

    return elem;
}

static void
filter_chain_RemoveFilter(struct filter_chain **fchain,
                          enum filter_type filter)
{
    struct filter_chain *prev = NULL;
    struct filter_chain *to_del;

    for (to_del = *fchain; to_del && to_del->filter != filter;
         to_del = to_del->next)
        prev = to_del;
    assert(to_del);
    if (!prev)
        *fchain = to_del->next;
    else
        prev->next = to_del->next;

    free(to_del);
}

static void
filter_desc_table_GetFilterTypes
(char const *vlc_filter_name,
 enum filter_type filter_types[NUM_MAX_EQUIVALENT_VLC_FILTERS])
{
    int j = 0;
    for (int i = 0; i < NUM_FILTERS; ++i)
        if (!strcmp(filter_desc_table[i].name_desc.vlc, vlc_filter_name))
        {
            assert(j < NUM_MAX_EQUIVALENT_VLC_FILTERS);
            filter_types[j++] = i;
        }
    assert(j);
    while (j < NUM_MAX_EQUIVALENT_VLC_FILTERS)
        filter_types[j++] = FILTER_NONE;
}

static inline NSString *
filter_desc_table_GetFilterName(enum filter_type type)
{ assert(type < NUM_FILTERS);
    return filter_desc_table[type].name_desc.ci;
}

static float
filter_ConvertParam(float f_vlc_val,
                    struct filter_param_desc const *param_desc)
{
    struct range clip_range = { param_desc->ranges[0].vlc.min,
                                param_desc->ranges[1].vlc.max
                                ? param_desc->ranges[1].vlc.max
                                : param_desc->ranges[0].vlc.max };
    f_vlc_val = VLC_CLIP(f_vlc_val, clip_range.min, clip_range.max);

    unsigned int range_idx;
    for (range_idx = 0; range_idx < 2; ++range_idx)
        if (f_vlc_val >= param_desc->ranges[range_idx].vlc.min &&
            f_vlc_val <= param_desc->ranges[range_idx].vlc.max)
            break;
    assert(range_idx < 2);

    return GET_CI_VALUE(f_vlc_val,
                        param_desc->ranges[range_idx].vlc,
                        param_desc->ranges[range_idx].ci);
}

static int
ParamsCallback(vlc_object_t *obj,
               char const *psz_var,
               vlc_value_t oldval, vlc_value_t newval,
               void *p_data)
{
    VLC_UNUSED(obj); VLC_UNUSED(oldval);
    struct filter_chain *filter = p_data;
    struct filter_param_desc const *filter_param_descs =
        filter_desc_table[filter->filter].param_descs;

    unsigned int i = 0;
    while (i < NUM_FILTER_PARAM_MAX &&
           strcmp(filter_param_descs[i].vlc, psz_var))
        ++i;
    assert(i < NUM_FILTER_PARAM_MAX);

    float new_vlc_val;
    if (filter_param_descs[i].vlc_type == VLC_VAR_FLOAT)
        new_vlc_val = newval.f_float;
    else if (filter_param_descs[i].vlc_type == VLC_VAR_INTEGER)
        new_vlc_val = newval.i_int;
    else
        vlc_assert_unreachable();

    vlc_atomic_store_float(filter->ci_params + i,
                           filter_ConvertParam(new_vlc_val,
                                               filter_param_descs + i));

    return VLC_SUCCESS;
}

static picture_t *
Filter(filter_t *filter, picture_t *src)
{
    struct ci_filters_ctx *ctx = filter->p_sys->ctx;
    enum filter_type filter_types[NUM_MAX_EQUIVALENT_VLC_FILTERS];

    filter_desc_table_GetFilterTypes(filter->p_sys->psz_filter, filter_types);
    if (ctx->fchain->filter != filter_types[0])
        return src;

    picture_t *dst = picture_NewFromFormat(&ctx->cvpx_pool_fmt);
    if (!dst)
        goto error;

    CVPixelBufferRef cvpx = cvpxpool_new_cvpx(ctx->cvpx_pool);
    if (!cvpx)
        goto error;

    if (cvpxpic_attach(dst, cvpx))
    {
        CFRelease(cvpx);
        goto error;
    }
    CFRelease(cvpx);

    @autoreleasepool {
        CIImage *ci_img = [CIImage imageWithCVImageBuffer: cvpxpic_get_ref(src)];
        if (!ci_img)
            goto error;

        for (struct filter_chain *fchain = ctx->fchain;
             fchain; fchain = fchain->next)
        {
            [fchain->ci_filter setValue: ci_img
                                 forKey: kCIInputImageKey];

            for (unsigned int i = 0; i < NUM_FILTER_PARAM_MAX &&
                     filter_desc_table[fchain->filter].param_descs[i].vlc; ++i)
            {
                NSString *ci_param_name =
                    filter_desc_table[fchain->filter].param_descs[i].ci;
                float ci_value = vlc_atomic_load_float(fchain->ci_params + i);

                [fchain->ci_filter setValue: [NSNumber numberWithFloat: ci_value]
                                     forKey: ci_param_name];
            }

            if (filter_desc_table[fchain->filter].pf_control)
                filter_desc_table[fchain->filter].pf_control(filter, fchain);
            ci_img = [fchain->ci_filter valueForKey: kCIOutputImageKey];
        }

        [ctx->ci_ctx render: ci_img
#if !TARGET_OS_IPHONE
                toIOSurface: CVPixelBufferGetIOSurface(cvpx)
#else
            toCVPixelBuffer: cvpx
#endif
                     bounds: [ci_img extent]
                 colorSpace: ctx->color_space];
    } /* autoreleasepool */

    CopyInfoAndRelease(dst, src);

    if (ctx->dst_converter)
    {
        dst = ctx->dst_converter->pf_video_filter(ctx->dst_converter, dst);
        if (!dst)
            return NULL;
    }

    filter->p_sys->mouse_moved = false;
    return dst;

error:
    if (dst)
        picture_Release(dst);
    picture_Release(src);
    filter->p_sys->mouse_moved = false;
    return NULL;
}

static int
Mouse(filter_t *filter, struct vlc_mouse_t *mouse,
      const struct vlc_mouse_t *old, const struct vlc_mouse_t *new)
{
    VLC_UNUSED(mouse);
    filter_sys_t *sys = filter->p_sys;
    sys->old_mouse = *old;
    sys->mouse = *new;
    sys->mouse_moved = true;
    return VLC_EGENERIC;
}

static int
Open_FilterInit(filter_t *filter, struct filter_chain *fchain)
{
    struct filter_param_desc const *filter_param_descs =
        filter_desc_table[fchain->filter].param_descs;
    NSString *ci_filter_name = filter_desc_table_GetFilterName(fchain->filter);
    if (ci_filter_name == nil)
    {
        char *psz_filter_name = var_InheritString(filter, "ci-filter");
        if (psz_filter_name)
            ci_filter_name = [NSString stringWithUTF8String:psz_filter_name];
        free(psz_filter_name);
    }

    fchain->ci_filter = [CIFilter filterWithName: ci_filter_name];
    if (!fchain->ci_filter)
    {
        msg_Warn(filter, "filter '%s' could not be created",
                 [ci_filter_name UTF8String]);
        return VLC_EGENERIC;
    }

    for (int i = 0; i < NUM_FILTER_PARAM_MAX && filter_param_descs[i].vlc; ++i)
    {
        NSString *ci_param_name = filter_param_descs[i].ci;
        char const *vlc_param_name = filter_param_descs[i].vlc;

        float vlc_param_val;
        if (filter_param_descs[i].vlc_type == VLC_VAR_FLOAT)
            vlc_param_val = var_CreateGetFloatCommand(filter, vlc_param_name);
        else if (filter_param_descs[i].vlc_type == VLC_VAR_INTEGER)
            vlc_param_val =
                (float)var_CreateGetIntegerCommand(filter, vlc_param_name);
        else
            vlc_assert_unreachable();

        vlc_atomic_init_float(fchain->ci_params + i,
                              filter_ConvertParam(vlc_param_val,
                                                  filter_param_descs + i));

        var_AddCallback(filter, filter_param_descs[i].vlc,
                        ParamsCallback, fchain);
    }
    if (filter_desc_table[fchain->filter].pf_init)
        filter_desc_table[fchain->filter].pf_init(filter, fchain);

    return VLC_SUCCESS;
}

static int
Open_CreateFilters(filter_t *filter, struct filter_chain **p_last_filter,
                   enum filter_type filter_types[NUM_MAX_EQUIVALENT_VLC_FILTERS])
{
    struct filter_chain *new_filter;

    for (unsigned int i = 0;
         i < NUM_MAX_EQUIVALENT_VLC_FILTERS
             && filter_types[i] != FILTER_NONE; ++i)
    {
        new_filter = filter_chain_AddFilter(p_last_filter, filter_types[i]);
        if (!new_filter)
            return VLC_EGENERIC;
        p_last_filter = &new_filter;
        if (Open_FilterInit(filter, new_filter) != VLC_SUCCESS)
        {
            for (unsigned int j = 0; j < i ; ++j)
                filter_chain_RemoveFilter(p_last_filter, filter_types[i]);
            return VLC_EGENERIC;
        }
    }

    return VLC_SUCCESS;
}

static picture_t *
CVPX_buffer_new(filter_t *converter)
{
    CVPixelBufferPoolRef pool = converter->owner.sys;
    CVPixelBufferRef cvpx = cvpxpool_new_cvpx(pool);
    if (!cvpx)
        return NULL;

    picture_t *pic = picture_NewFromFormat(&converter->fmt_out.video);
    if (!pic || cvpxpic_attach(pic, cvpx))
    {
        CFRelease(cvpx);
        return NULL;
    }
    CFRelease(cvpx);

    return pic;
}

static void
Close_RemoveConverters(filter_t *filter, struct ci_filters_ctx *ctx)
{
    VLC_UNUSED(filter);
    if (ctx->dst_converter)
    {
        module_unneed(ctx->dst_converter, ctx->dst_converter->p_module);
        vlc_object_release(ctx->dst_converter);
        CVPixelBufferPoolRelease(ctx->outconv_cvpx_pool);
    }
}

static int
Open_AddConverter(filter_t *filter, struct ci_filters_ctx *ctx)
{
    ctx->cvpx_pool_fmt = filter->fmt_in.video;
    ctx->cvpx_pool_fmt.i_chroma = VLC_CODEC_CVPX_BGRA;
    ctx->cvpx_pool = cvpxpool_create(&ctx->cvpx_pool_fmt, 3);
    if (!ctx->cvpx_pool)
        goto error;

    ctx->dst_converter = vlc_object_create(filter, sizeof(filter_t));
    if (!ctx->dst_converter)
        goto error;

    ctx->dst_converter->fmt_in = filter->fmt_out;
    ctx->dst_converter->fmt_out = filter->fmt_out;
    ctx->dst_converter->fmt_in.video.i_chroma =
    ctx->dst_converter->fmt_in.i_codec = VLC_CODEC_CVPX_BGRA;

    ctx->outconv_cvpx_pool =
        cvpxpool_create(&filter->fmt_out.video, 2);
    if (!ctx->outconv_cvpx_pool)
        goto error;

    ctx->dst_converter->owner.sys = ctx->outconv_cvpx_pool;
    ctx->dst_converter->owner.video.buffer_new = CVPX_buffer_new;

    ctx->dst_converter->p_module =
        module_need(ctx->dst_converter, "video converter", NULL, false);
    if (!ctx->dst_converter->p_module)
        goto error;

    return VLC_SUCCESS;

error:
    if (ctx->dst_converter)
    {
        if (ctx->dst_converter->p_module)
            module_unneed(ctx->dst_converter, ctx->dst_converter->p_module);
        vlc_object_release(ctx->dst_converter);
        if (ctx->outconv_cvpx_pool)
            CVPixelBufferPoolRelease(ctx->outconv_cvpx_pool);
    }
    return VLC_EGENERIC;
}

#if MAC_OS_X_VERSION_MIN_ALLOWED <= MAC_OS_X_VERSION_10_11
const CFStringRef kCGColorSpaceITUR_709 = CFSTR("kCGColorSpaceITUR_709");
#endif

#if TARGET_OS_IPHONE
# define CI_HANDLE_COLORSPACES (NSFoundationVersionNumber >= 1240)
#else
# define CI_HANDLE_COLORSPACES (NSFoundationVersionNumber >= 1252)
#endif

static int
Open(vlc_object_t *obj, char const *psz_filter)
{
    filter_t *filter = (filter_t *)obj;

    switch (filter->fmt_in.video.i_chroma)
    {
        case VLC_CODEC_CVPX_NV12:
        case VLC_CODEC_CVPX_UYVY:
        case VLC_CODEC_CVPX_I420:
        case VLC_CODEC_CVPX_BGRA:
            if (!CI_HANDLE_COLORSPACES)
            {
                msg_Warn(obj, "iOS/macOS version is too old, aborting...");
                return VLC_EGENERIC;
            }
            break;
        default:
            return VLC_EGENERIC;
    }

    filter->p_sys = calloc(1, sizeof(filter_sys_t));
    if (!filter->p_sys)
        return VLC_ENOMEM;

    enum filter_type filter_types[NUM_MAX_EQUIVALENT_VLC_FILTERS];
    filter_desc_table_GetFilterTypes(psz_filter, filter_types);

    struct ci_filters_ctx *ctx = var_InheritAddress(filter, "ci-filters-ctx");
    if (!ctx)
    {
        ctx = calloc(1, sizeof(*ctx));
        if (!ctx)
            goto error;

        if (filter->fmt_in.video.i_chroma != VLC_CODEC_CVPX_NV12
         && filter->fmt_in.video.i_chroma != VLC_CODEC_CVPX_BGRA
         && Open_AddConverter(filter, ctx))
            goto error;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
        ctx->color_space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
#pragma clang diagnostic pop

#if !TARGET_OS_IPHONE
        CGLContextObj glctx = var_InheritAddress(filter, "macosx-glcontext");
        if (!glctx)
        {
            msg_Err(filter, "can't find 'macosx-glcontext' var");
            goto error;
        }
        ctx->ci_ctx = [CIContext contextWithCGLContext: glctx
                                           pixelFormat: nil
                                            colorSpace: nil
                                               options: nil];
#else
        CVEAGLContext eaglctx = var_InheritAddress(filter, "ios-eaglcontext");
        if (!eaglctx)
        {
            msg_Err(filter, "can't find 'ios-eaglcontext' var");
            goto error;
        }
        ctx->ci_ctx = [CIContext contextWithEAGLContext: eaglctx];
#endif
        if (!ctx->ci_ctx)
            goto error;

        if (!ctx->cvpx_pool)
        {
            ctx->cvpx_pool_fmt = filter->fmt_out.video;
            ctx->cvpx_pool = cvpxpool_create(&ctx->cvpx_pool_fmt, 2);
            if (!ctx->cvpx_pool)
                goto error;
        }

        if (Open_CreateFilters(filter, &ctx->fchain, filter_types))
            goto error;

        var_Create(filter->obj.parent, "ci-filters-ctx", VLC_VAR_ADDRESS);
        var_SetAddress(filter->obj.parent, "ci-filters-ctx", ctx);
    }
    else if (Open_CreateFilters(filter, &ctx->fchain, filter_types))
        goto error;

    filter->p_sys->psz_filter = psz_filter;
    filter->p_sys->ctx = ctx;

    filter->pf_video_filter = Filter;
    filter->pf_video_mouse = Mouse;

    return VLC_SUCCESS;

error:
    if (ctx)
    {
        if (ctx->color_space)
            CGColorSpaceRelease(ctx->color_space);
        Close_RemoveConverters(filter, ctx);
        if (ctx->cvpx_pool)
            CVPixelBufferPoolRelease(ctx->cvpx_pool);
        free(ctx);
    }
    free(filter->p_sys);
    return VLC_EGENERIC;
}

static int
OpenAdjust(vlc_object_t *obj)
{
    return Open(obj, "adjust");
}

static int
OpenInvert(vlc_object_t *obj)
{
    return Open(obj, "invert");
}

static int
OpenPosterize(vlc_object_t *obj)
{
    return Open(obj, "posterize");
}

static int
OpenSepia(vlc_object_t *obj)
{
    return Open(obj, "sepia");
}

static int
OpenSharpen(vlc_object_t *obj)
{
    return Open(obj, "sharpen");
}

static void
Close(vlc_object_t *obj)
{
    filter_t *filter = (filter_t *)obj;
    struct ci_filters_ctx *ctx = filter->p_sys->ctx;
    enum filter_type filter_types[NUM_MAX_EQUIVALENT_VLC_FILTERS];

    filter_desc_table_GetFilterTypes(filter->p_sys->psz_filter, filter_types);
    for (unsigned int i = 0;
         i < NUM_MAX_EQUIVALENT_VLC_FILTERS && filter_types[i] != FILTER_NONE;
         ++i)
        filter_chain_RemoveFilter(&ctx->fchain, filter_types[i]);

    if (!ctx->fchain)
    {
        Close_RemoveConverters(filter, ctx);
        if (ctx->cvpx_pool)
            CVPixelBufferPoolRelease(ctx->cvpx_pool);
        if (ctx->color_space)
            CGColorSpaceRelease(ctx->color_space);
        free(ctx);
        var_Destroy(filter->obj.parent, "ci-filters-ctx");
    }
    free(filter->p_sys);
}

vlc_module_begin()
    set_capability("video filter", 0)
    set_category(CAT_VIDEO)
    set_subcategory(SUBCAT_VIDEO_VFILTER)
    set_description(N_("Mac OS X hardware video filters"))

    add_submodule()
    set_callbacks(OpenAdjust, Close)
    add_shortcut("adjust")

    add_submodule()
    set_callbacks(OpenInvert, Close)
    add_shortcut("invert")

    add_submodule()
    set_callbacks(OpenPosterize, Close)
    add_shortcut("posterize")

    add_submodule()
    set_callbacks(OpenSepia, Close)
    add_shortcut("sepia")

    add_submodule()
    set_callbacks(OpenSharpen, Close)
    add_shortcut("sharpen")
vlc_module_end()

// vim9_ios: compile-time configuration guards for Apple sandbox targets.
//
// This header is included from vim.h (after system headers) to ensure we
// don't accidentally enable features that rely on process creation APIs
// (fork/exec/posix_spawn) which are not available in the App Store sandbox.

#ifndef VIM_IOS_SANDBOX_H
#define VIM_IOS_SANDBOX_H

#ifdef VIM_APPLE_SANDBOX

#ifndef USE_SYSTEM
# error "Apple sandbox builds must define USE_SYSTEM (fork/exec is not available)"
#endif

// These features currently rely on fork/exec-based implementations.
#ifdef FEAT_JOB_CHANNEL
# error "Apple sandbox builds must not enable FEAT_JOB_CHANNEL"
#endif

#ifdef FEAT_NETBEANS_INTG
# error "Apple sandbox builds must not enable FEAT_NETBEANS_INTG"
#endif

#endif // VIM_APPLE_SANDBOX

#endif // VIM_IOS_SANDBOX_H

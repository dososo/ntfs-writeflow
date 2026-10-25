dnl Stub AM_PATH_LIBGCRYPT for the FSKit build.
dnl The real macro ships with libgcrypt's dev files; we don't build the optional
dnl crypto/EFS utilities, so this stub just executes ACTION-IF-NOT-FOUND ($3).
dnl AM_PATH_LIBGCRYPT([MIN-VERSION], [ACTION-IF-FOUND], [ACTION-IF-NOT-FOUND])
AC_DEFUN([AM_PATH_LIBGCRYPT],
[
  LIBGCRYPT_CFLAGS=""
  LIBGCRYPT_LIBS=""
  AC_SUBST(LIBGCRYPT_CFLAGS)
  AC_SUBST(LIBGCRYPT_LIBS)
  ifelse([$3], , :, [$3])
])

#ifndef DESKHELM_H
#define DESKHELM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	DESKHELM_STATUS_OK = 0,
	DESKHELM_STATUS_RUNTIME_ERROR = 1,
	DESKHELM_STATUS_INVALID_ARGUMENT = 2,
	DESKHELM_STATUS_PANIC = 3,
};

typedef struct DeskHelmVolumeResult {
	/* Current or accepted volume value. */
	uint16_t current;
	uint16_t maximum;
	char *display;
	char *error;
} DeskHelmVolumeResult;

typedef struct DeskHelmSession DeskHelmSession;

int32_t deskhelm_read_volume(DeskHelmVolumeResult *out_result);
int32_t deskhelm_set_volume(int32_t level, DeskHelmVolumeResult *out_result);
int32_t deskhelm_session_create(
	DeskHelmSession **out_session,
	DeskHelmVolumeResult *out_result
);
int32_t deskhelm_session_read(
	DeskHelmSession *session,
	DeskHelmVolumeResult *out_result
);
int32_t deskhelm_session_set(
	DeskHelmSession *session,
	int32_t level,
	DeskHelmVolumeResult *out_result
);
int32_t deskhelm_session_write(
	DeskHelmSession *session,
	int32_t level,
	DeskHelmVolumeResult *out_result
);
void deskhelm_session_free(DeskHelmSession *session);
void deskhelm_volume_result_free(DeskHelmVolumeResult *result);

#ifdef __cplusplus
}
#endif

#endif

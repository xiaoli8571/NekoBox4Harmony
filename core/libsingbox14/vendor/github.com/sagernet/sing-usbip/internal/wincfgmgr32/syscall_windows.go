package wincfgmgr32

import "golang.org/x/sys/windows"

//go:generate go run golang.org/x/sys/windows/mkwinsyscall -output zsyscall_windows.go syscall_windows.go

type (
	CONFIGRET       = windows.CONFIGRET
	HCMNOTIFICATION uintptr
)

const (
	CM_NOTIFY_FILTER_TYPE_DEVICEINTERFACE uint32 = 0

	CM_NOTIFY_ACTION_DEVICEINTERFACEARRIVAL uint32 = 0
	CM_NOTIFY_ACTION_DEVICEINTERFACEREMOVAL uint32 = 1
)

type CM_NOTIFY_FILTER struct {
	cbSize     uint32
	Flags      uint32
	FilterType uint32
	Reserved   uint32
	ClassGUID  windows.GUID
	_          [windows.MAX_DEVICE_ID_LEN*2 - 16]byte
}

type CM_NOTIFY_EVENT_DATA struct {
	FilterType uint32
	Reserved   uint32
}

// https://learn.microsoft.com/en-us/windows/win32/api/cfgmgr32/nf-cfgmgr32-cm_register_notification
//sys CM_Register_Notification(filter *CM_NOTIFY_FILTER, context uintptr, callback uintptr, notifyContext *HCMNOTIFICATION) (ret CONFIGRET) = cfgmgr32.CM_Register_Notification

// https://learn.microsoft.com/en-us/windows/win32/api/cfgmgr32/nf-cfgmgr32-cm_unregister_notification
//sys CM_Unregister_Notification(notifyContext HCMNOTIFICATION) (ret CONFIGRET) = cfgmgr32.CM_Unregister_Notification

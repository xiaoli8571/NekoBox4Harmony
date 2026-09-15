package wincfgmgr32

import (
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

type DeviceInterfaceNotification struct {
	pinner   runtime.Pinner
	callback func(action uint32)
	handle   HCMNOTIFICATION
}

var notificationCallback = sync.OnceValue(func() uintptr {
	return windows.NewCallback(func(notify HCMNOTIFICATION, context *DeviceInterfaceNotification, action uint32, eventData *CM_NOTIFY_EVENT_DATA, eventDataSize uint32) uintptr {
		context.callback(action)
		return 0
	})
})

func RegisterDeviceInterfaceNotification(classGUID windows.GUID, callback func(action uint32)) (*DeviceInterfaceNotification, error) {
	notification := &DeviceInterfaceNotification{callback: callback}
	filter := CM_NOTIFY_FILTER{
		FilterType: CM_NOTIFY_FILTER_TYPE_DEVICEINTERFACE,
		ClassGUID:  classGUID,
	}
	filter.cbSize = uint32(unsafe.Sizeof(filter))
	notification.pinner.Pin(notification)
	result := CM_Register_Notification(&filter, uintptr(unsafe.Pointer(notification)), notificationCallback(), &notification.handle)
	if result != windows.CR_SUCCESS {
		notification.pinner.Unpin()
		return nil, result
	}
	return notification, nil
}

// Close blocks until in-flight callbacks return; the callback must not call Close.
func (n *DeviceInterfaceNotification) Close() error {
	if n.handle == 0 {
		return nil
	}
	result := CM_Unregister_Notification(n.handle)
	n.handle = 0
	n.pinner.Unpin()
	if result != windows.CR_SUCCESS {
		return result
	}
	return nil
}

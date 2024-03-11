//
//  Daemon for IVPN Client Desktop
//  https://github.com/tahirmahm123/vpn-desktop-app
//
//  Created by Stelnykovych Alexandr.
//  Copyright (c) 2023 IVPN Limited.
//
//  This file is part of the Daemon for IVPN Client Desktop.
//
//  The Daemon for IVPN Client Desktop is free software: you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option) any later version.
//
//  The Daemon for IVPN Client Desktop is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
//  or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
//  details.
//
//  You should have received a copy of the GNU General Public License
//  along with the Daemon for IVPN Client Desktop. If not, see <https://www.gnu.org/licenses/>.
//

//go:build linux
// +build linux

package dns

import (
	"fmt"
	"net"
	"os"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/tahirmahm123/vpn-desktop-app/daemon/service/platform"
)

var (
	resolvFile             string      = "/etc/resolv.conf"
	resolvBackupFile       string      = "/etc/resolv.conf.ivpnsave"
	defaultFilePermissions os.FileMode = 0644

	done chan struct{}
)

func init() {
	done = make(chan struct{})
}

// implInitialize doing initialization stuff (called on application start)
func rconf_implInitialize() error {
	// check if backup DNS file exists
	if _, err := os.Stat(resolvBackupFile); err != nil {
		// nothing to restore
		return nil
	}

	log.Info("Detected DNS configuration from the previous VPN connection. Restoring OS-default DNS values ...")
	// restore it
	if err := rconf_implDeleteManual(nil); err != nil {
		return fmt.Errorf("failed to restore DNS to default: %w", err)
	}

	return nil
}

func rconf_implPause(localInterfaceIP net.IP) error {
	if !rconf_isBackupExists() {
		// The backup for the OS-defined configuration not exists.
		// It seems, we are not connected. Nothing to pause.
		return nil
	}

	// stop file change monitoring
	rconf_stopDNSChangeMonitoring()

	// restore original OS-default DNS configuration
	ret := rconf_restoreBackup()

	return ret
}

func rconf_implResume(localInterfaceIP net.IP) error {
	return nil
}

// Set manual DNS.
// 'localInterfaceIP' - not in use for Linux implementation
func rconf_implSetManual(dnsCfg DnsSettings, localInterfaceIP net.IP) (dnsInfoForFirewall DnsSettings, retErr error) {
	rconf_stopDNSChangeMonitoring()

	if dnsCfg.IsEmpty() {
		return DnsSettings{}, rconf_implDeleteManual(nil)
	}

	createBackupIfNotExists := func() (created bool, er error) {
		isOwerwriteIfExists := false
		return rconf_createBackup(isOwerwriteIfExists)
	}

	saveNewConfig := func() error {
		createBackupIfNotExists()

		// create new configuration
		out, err := os.OpenFile(resolvFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, defaultFilePermissions)
		if err != nil {
			return fmt.Errorf("failed to update DNS configuration (%w)", err)
		}

		if _, err := out.WriteString(fmt.Sprintf("# resolv.conf autogenerated by '%s'\n\nnameserver %s\n", os.Args[0], dnsCfg.Ip().String())); err != nil {
			return fmt.Errorf("failed to change DNS configuration: %w", err)
		}

		if err := out.Sync(); err != nil {
			return fmt.Errorf("failed to change DNS configuration: %w", err)
		}
		return nil
	}

	_, err := createBackupIfNotExists()
	if err != nil {
		// Check if we are running in snap environment
		if platform.GetSnapEnvs() != nil {
			// Check if snap allowed to modify resolv.conf:
			allowed, userErrMsgIfNotAllowed, snapCheckErr := platform.IsSnapAbleManageResolvconf()
			if snapCheckErr != nil {
				log.Error("IsSnapAbleManageResolvconf: ", snapCheckErr)
			}
			if !allowed && len(userErrMsgIfNotAllowed) > 0 {
				return DnsSettings{}, fmt.Errorf("%w\n\n%s", err, userErrMsgIfNotAllowed)
			}
		}
		return DnsSettings{}, err
	}

	// Save new configuration
	if err := saveNewConfig(); err != nil {
		return DnsSettings{}, err
	}

	// enable file change monitoring
	go func() {
		w, err := fsnotify.NewWatcher()
		if err != nil {
			log.Error(fmt.Errorf("failed to start DNS-change monitoring (fsnotify error): %w", err))
			return
		}

		log.Info("DNS-change monitoring started")
		defer func() {
			log.Info("DNS-change monitoring stopped")
			w.Close()
		}()

		for {
			// start watching file
			err = w.Add(resolvFile)
			if err != nil {
				log.Error(fmt.Errorf("failed to start DNS-change monitoring (fsnotify error): %w", err))
				return
			}

			// wait for changes
			var evt fsnotify.Event
			select {
			case evt = <-w.Events:
			case <-done:
				// monitoring stopped
				return
			}

			//stop watching file
			if err := w.Remove(resolvFile); err != nil {
				log.Error(fmt.Errorf("failed to remove watcher (fsnotify error): %w", err))
			}

			// wait 2 seconds for reaction (in case if we are stopping of when multiple consecutive file changes)
			select {
			case <-time.After(time.Second * 2):
			case <-done:
				// monitoring stopped
				return
			}

			// restore DNS configuration
			log.Info(fmt.Sprintf("DNS-change monitoring: DNS was changed outside [%s]. Restoring ...", evt.Op.String()))
			if err := saveNewConfig(); err != nil {
				log.Error(err)
			}
		}
	}()

	return dnsCfg, nil
}

// DeleteManual - reset manual DNS configuration to default
// 'localInterfaceIP' (obligatory only for Windows implementation) - local IP of VPN interface
func rconf_implDeleteManual(localInterfaceIP net.IP) error {
	// stop file change monitoring
	rconf_stopDNSChangeMonitoring()
	return rconf_restoreBackup()
}

func rconf_stopDNSChangeMonitoring() {
	// stop file change monitoring
	select {
	case done <- struct{}{}:
		break
	default:
		break
	}
}

func rconf_isBackupExists() bool {
	_, err := os.Stat(resolvBackupFile)
	return err == nil
}

func rconf_createBackup(isOverwriteIfExists bool) (created bool, er error) {
	if _, err := os.Stat(resolvFile); err != nil {
		// source file not exists
		return false, fmt.Errorf("failed to backup DNS configuration (file availability check failed): %w", err)
	}

	if _, err := os.Stat(resolvBackupFile); err == nil {
		// backup file already exists
		if !isOverwriteIfExists {
			return false, nil
		}
	}

	if err := os.Rename(resolvFile, resolvBackupFile); err != nil {
		return false, fmt.Errorf("failed to backup DNS configuration: %w", err)
	}
	return true, nil
}

func rconf_restoreBackup() error {
	if _, err := os.Stat(resolvBackupFile); err != nil {
		// nothing to restore
		return nil
	}

	// restore original configuration
	if err := os.Rename(resolvBackupFile, resolvFile); err != nil {
		return fmt.Errorf("failed to restore DNS configuration: %w", err)
	}

	return nil
}

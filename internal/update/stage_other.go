//go:build !windows && !linux && !darwin

package update

import "errors"

const assetName = ""

func canInstall() bool { return false }

func stage(asset, func(done, total int64)) (plan, error) {
	return plan{}, errors.New("на этой системе YAMP не умеет обновляться сам")
}

func Cleanup() {}

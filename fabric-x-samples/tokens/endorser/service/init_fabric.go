//go:build !fabricx

/*
Copyright IBM Corp. All Rights Reserved.

SPDX-License-Identifier: Apache-2.0
*/

package service

import "context"

// Init is a no-op on classic Fabric networks: the token namespace and its public
// parameters are deployed together with the chaincode during network setup.
func (f FabricSmartClient) Init(context.Context) error {
	logger.Info("init: nothing to do, public parameters are deployed with the namespace chaincode")
	return nil
}

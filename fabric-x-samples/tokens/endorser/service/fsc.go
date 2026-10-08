/*
Copyright IBM Corp. All Rights Reserved.

SPDX-License-Identifier: Apache-2.0
*/

package service

import (
	"context"
	"os"
	"reflect"

	"github.com/hyperledger-labs/fabric-smart-client/node"
	"github.com/hyperledger-labs/fabric-smart-client/platform/common/services/logging"
	"github.com/LFDT-Panurus/panurus/token/services/config"
	"github.com/LFDT-Panurus/panurus/token/services/network/fabricx/tms"
)

var logger = logging.MustGetLogger()

type FabricSmartClient struct {
	node *node.Node
}

func NewFSC(node *node.Node) *FabricSmartClient {
	return &FabricSmartClient{node: node}
}

// Init must be called for fabric-x networks to initialize the token parameters on the ledger.
//
// DeployTMSs (and DeployTMS) source the public parameters to deploy by reading them back
// from the ledger via the query service, so they only work once a TMS is already deployed.
// On first init the ledger has nothing yet, so that read returns empty and would otherwise
// get written back as the "public parameters", leaving the namespace permanently empty.
// We load each configured TMS's public parameters from its local `publicParameters.path`
// file instead and deploy that via DeployTMSWithPP.
func (f FabricSmartClient) Init(ctx context.Context) error {
	logger.Info("initializing token parameters")
	dep, err := tms.GetTMSDeployerService(f.node)
	if err != nil {
		return err
	}

	cs, err := f.node.GetService(reflect.TypeFor[*config.Service]())
	if err != nil {
		return err
	}
	configService := cs.(*config.Service)

	configurations, err := configService.Configurations()
	if err != nil {
		return err
	}

	for _, cfg := range configurations {
		var publicParameters struct {
			Path string `yaml:"path"`
		}
		if err := cfg.UnmarshalKey("publicParameters", &publicParameters); err != nil || len(publicParameters.Path) == 0 {
			logger.Warnf("no local public parameters configured for TMS [%s], skipping", cfg.ID())
			continue
		}

		ppRaw, err := os.ReadFile(publicParameters.Path)
		if err != nil {
			return err
		}

		if err := dep.DeployTMSWithPP(cfg.ID(), ppRaw); err != nil {
			return err
		}
	}
	return nil
}

//go:build fabricx

/*
Copyright IBM Corp. All Rights Reserved.

SPDX-License-Identifier: Apache-2.0
*/

package service

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"reflect"
	"sync"
	"time"

	"github.com/LFDT-Panurus/panurus/token/services/config"
	"github.com/LFDT-Panurus/panurus/token/services/network/fabricx/pp"
	"github.com/LFDT-Panurus/panurus/token/services/network/fabricx/tms"
)

const (
	ppCommitTimeout      = 2 * time.Minute
	ppCommitPollInterval = time.Second
)

// initMu serializes Init so concurrent calls can't both see an empty ledger and deploy twice.
var initMu sync.Mutex

// Init must be called for fabric-x networks to initialize the token parameters on the ledger.
//
// DeployTMSs (and DeployTMS) source the public parameters to deploy by reading them back
// from the ledger via the query service, so they only work once a TMS is already deployed.
// On first init the ledger has nothing yet, so that read returns empty and would otherwise
// get written back as the "public parameters", leaving the namespace permanently empty.
// We load each configured TMS's public parameters from its local `publicParameters.path`
// file instead and deploy that via DeployTMSWithPP.
func (f FabricSmartClient) Init(ctx context.Context) error {
	initMu.Lock()
	defer initMu.Unlock()

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

	l, err := f.node.GetService(reflect.TypeFor[*pp.Loader]())
	if err != nil {
		return err
	}
	ppFetcher, ok := l.(*pp.PublicParametersService)
	if !ok {
		return fmt.Errorf("unexpected public parameters service type %T", l)
	}

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

		// Redeploying identical parameters bumps the setup key's ledger version without the
		// nodes reloading them (same hash), so every later token transaction fails with an
		// MVCC conflict. Only deploy when the ledger doesn't already hold these parameters.
		onLedger, err := ppFetcher.Fetch(cfg.ID().Network, cfg.ID().Channel, cfg.ID().Namespace)
		if err != nil {
			return err
		}
		if bytes.Equal(onLedger, ppRaw) {
			logger.Infof("public parameters for TMS [%s] already deployed, skipping", cfg.ID())
			continue
		}

		if err := dep.DeployTMSWithPP(cfg.ID(), ppRaw); err != nil {
			return err
		}

		// DeployTMSWithPP only submits the transaction. Wait for it to commit so that a
		// follow-up Init sees the parameters on the ledger instead of deploying them again.
		if err := waitForPublicParams(ctx, ppFetcher, cfg.ID().Network, cfg.ID().Channel, cfg.ID().Namespace, ppRaw); err != nil {
			return err
		}
		logger.Infof("public parameters for TMS [%s] committed", cfg.ID())
	}
	return nil
}

func waitForPublicParams(ctx context.Context, fetcher *pp.PublicParametersService, network, channel, namespace string, want []byte) error {
	ctx, cancel := context.WithTimeout(ctx, ppCommitTimeout)
	defer cancel()
	ticker := time.NewTicker(ppCommitPollInterval)
	defer ticker.Stop()
	for {
		got, err := fetcher.Fetch(network, channel, namespace)
		if err == nil && bytes.Equal(got, want) {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("public parameters for [%s,%s,%s] not committed: %w", network, channel, namespace, ctx.Err())
		case <-ticker.C:
		}
	}
}

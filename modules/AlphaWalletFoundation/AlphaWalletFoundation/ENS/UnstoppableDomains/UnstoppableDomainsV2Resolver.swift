//
//  UnstoppableDomainsV2Resolver.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 27.01.2022.
//

import Foundation
import Combine
import AlphaWalletCore
import AlphaWalletENS
import AlphaWalletLogger
import AlphaWalletWeb3
import SwiftyJSON

struct UnstoppableDomainsV2ApiError: Error {
    var localizedDescription: String
}

class UnstoppableDomainsV2Resolver {
    private let fallbackServer: RPCServer
    private let storage: EnsRecordsStorage
    private let networkProvider: UnstoppableDomainsV2NetworkProvider

    init(fallbackServer: RPCServer, storage: EnsRecordsStorage, networkService: NetworkService) {
        self.fallbackServer = fallbackServer
        self.storage = storage
        self.networkProvider = .init(networkService: networkService)
    }

    func resolveDomain(address: AlphaWallet.Address, server actualServer: RPCServer) -> AnyPublisher<String, PromiseError> {
        let fallbackServer = fallbackServer
        return Just(actualServer)
            .setFailureType(to: PromiseError.self)
            .flatMap { [self] actualServer in
                _resolveDomain(address: address, server: actualServer)
            .catch { error -> AnyPublisher<String, PromiseError> in
                if actualServer == fallbackServer {
                    return Fail(error: error).eraseToAnyPublisher()
                } else {
                    return _resolveDomain(address: address, server: fallbackServer)
                }
            }.receive(on: RunLoop.main)
            }.eraseToAnyPublisher()
    }

    private func _resolveDomain(address: AlphaWallet.Address, server: RPCServer) -> AnyPublisher<String, PromiseError> {
        if let cachedResult = cachedEnsValue(for: address) {
            return .just(cachedResult)
        }

        let parameters = [EthereumAddress(address: address)] as [AnyObject]
        let abiString = """
                        [ 
                          { 
                            "constant": false, 
                            "inputs": [ 
                              {"address": "","type": "address"}, 
                            ], 
                            "name": "reverseNameOf", 
                            "outputs": [{"name": "", "type": "string"}], 
                            "type": "function" 
                          },
                        ]
                        """
        return callSmartContract(withServer: server, contract: AlphaWallet.Address(string: "0xa9a6A3626993D487d2Dbda3173cf58cA1a9D9e9f")!, functionName: "reverseNameOf", abiString: abiString, parameters: parameters)
            .publisher()
            .tryMap { result in
                if let name = result["0"] as? String, !name.isEmpty {
                    return name
                } else {
                    throw UnstoppableDomainsV2ApiError(localizedDescription: "Can't reverse resolve \(address.eip55String) on: \(server)")
                }
            }
            .mapError { PromiseError.some(error: $0) }
            .eraseToAnyPublisher()
    }

    func resolveAddress(forName name: String) -> AnyPublisher<AlphaWallet.Address, PromiseError> {
        if let value = AlphaWallet.Address(string: name) {
            return .just(value)
        }

        if let value = self.cachedAddressValue(for: name) {
            return .just(value)
        }

        return Just(name)
            .setFailureType(to: PromiseError.self)
            .flatMap { [networkProvider] name -> AnyPublisher<AlphaWallet.Address, PromiseError> in
                infoLog("[UnstoppableDomains] resolving name: \(name)…")
                return networkProvider.resolveAddress(forName: name)
                    .handleEvents(receiveOutput: { address in
                        let key = EnsLookupKey(nameOrAddress: name, server: self.fallbackServer)
                        self.storage.addOrUpdate(record: .init(key: key, value: .address(address)))
                    }).share()
                    .eraseToAnyPublisher()
            }.eraseToAnyPublisher()
    }
}

extension UnstoppableDomainsV2Resolver: CachedEnsResolutionServiceType {
    func cachedEnsValue(for address: AlphaWallet.Address) -> String? {
        let key = EnsLookupKey(nameOrAddress: address.eip55String, server: fallbackServer)
        switch storage.record(for: key, expirationTime: Constants.Ens.recordExpiration)?.value {
        case .ens(let ens):
            return ens
        case .record, .address, .none:
            return nil
        }
    }
}

extension UnstoppableDomainsV2Resolver: CachebleAddressResolutionServiceType {
    func cachedAddressValue(for name: String) -> AlphaWallet.Address? {
        let key = EnsLookupKey(nameOrAddress: name, server: fallbackServer)
        switch storage.record(for: key, expirationTime: Constants.Ens.recordExpiration)?.value {
        case .address(let address):
            return address
        case .record, .ens, .none:
            return nil
        }
    }
}

extension UnstoppableDomainsV2Resolver {
    enum DecodingError: Error {
        case domainNotFound
        case ownerNotFound
        case idNotFound
        case errorMessageNotFound
        case errorCodeNotFound
    }

    struct AddressResolution {
        struct Meta {
            let networkId: Int?
            let domain: String
            let owner: AlphaWallet.Address?
            let blockchain: String?
            let registry: String?

            init(json: JSON) throws {
                guard let domain = json["domain"].string else {
                    throw DecodingError.domainNotFound
                }
                self.domain = domain
                self.owner = json["owner"].string.flatMap { value in
                    AlphaWallet.Address(uncheckedAgainstNullAddress: value)
                }
                networkId = json["networkId"].int
                blockchain = json["blockchain"].string
                registry = json["registry"].string
            }
        }

        struct Response {
            let meta: Meta

            init(json: JSON) throws {
                meta = try Meta(json: json["meta"])
            }
        }
    }
}
//
//  AmazonS3.swift
//
//  Created by Ben Spratling on 3/30/17.
//
//

import Foundation
import Dispatch
import Cryptor

// See https://stackoverflow.com/questions/58592508
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

//Based on http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html


extension UInt8 {
	private static let hexChars:[String] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
	var hex:String {
		let lowBits:UInt8 = self & 0x0F
		let highBits:UInt8 = (self >> 4)
		return UInt8.hexChars[Int(highBits)] + UInt8.hexChars[Int(lowBits)]
	}
}


extension URLRequest {
	
	///adds an Authorization header
	/// uses chunking if a chunk size is specified, or if the httpBody is a stream.
	/// sends as a single chunk if the body is Data and the chunk
	/// chunking is ignored on non-apple platforms
    // 2/3/19; CGP; Added date parameter for testing.
    // 2/5/19; CGP; Added optional url queryParams-- See https://github.com/benspratling4/SwiftAWSSignatureV4/issues/5; if you use this, don't give query params in the URL.
	public mutating func sign(for account:AWSAccount, urlQueryParams: Dictionary<String, String>? = nil, signPayload:Bool = false, chunkSize:Int? = nil, date: Date? = nil) {
		var now:Date = Date()
        if let date = date {
            now = date
        }
		sign(for: account, urlQueryParams: urlQueryParams, now: now, signPayload:signPayload, chunkSize:chunkSize)
	}
	
	///primarily for testing
	mutating func sign(for account:AWSAccount, urlQueryParams: Dictionary<String, String>? = nil, now:Date, signPayload:Bool = false, chunkSize:Int? = nil) {
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
		if let chunkSize = chunkSize {
			if let dataBody = httpBody {
				httpBodyStream = InputStream(data: dataBody)
				httpBody = nil
			}
			signChunkingRequest(for: account, date: now, chunkSize: chunkSize)
			return
		} else if httpBodyStream != nil {
			signChunkingRequest(for: account, date: now, chunkSize:URLRequest.minimumAWSChunkSize)	//default chunk size
			return
		}
#endif
		//regular data signing
		let nowComponents:DateComponents = AWSAccount.dateComponents(for:now)
		//add some headers
		addPreAuthHeaders(date:now, signPayload:signPayload)
		//auth header
		let header = newAuthorizationHeader(account: account, urlQueryParams: urlQueryParams, now: now, nowComponents: nowComponents, signPayload:signPayload)
		setValue(header, forHTTPHeaderField: "Authorization")
	}
	
	
	///create headers which should be added before auth signing happens
	mutating func addPreAuthHeaders(date:Date, signPayload:Bool = false) {
		let nowComponents:DateComponents = AWSAccount.dateComponents(for:date)
		//credential
		//setValue(AWSAccount.credentialString(now:nowComponents), forHTTPHeaderField: "x-amz-credential")
        
        // 2/3/19; CGP; Changed from key "Date" to "X-Amz-Date"-- because this is what is in the AWS specs.
		setValue(HTTPDate(now:nowComponents, date: date), forHTTPHeaderField: "X-Amz-Date")
		if let _ = httpBody {
			if signPayload {
				//TODO: verify me
				setValue(sha256HashedBody?.map{$0.hex}.joined(), forHTTPHeaderField: "x-amz-content-sha256")
			} else {
				setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
			}
		} else {
			//the hash of an empty string
            // 2/3/19; CGP; This isn't needed or required.
			// setValue("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", forHTTPHeaderField: "x-amz-content-sha256")
		}
	}

    /* 2/3/19; CGP; When used for signing AWS SNS CreatePlatformEndpoint request, I get the error:
            <Message>Date must be in ISO-8601 \'basic format\'. Got \'Sun, 03 Feb 2019 20:14:11 GMT\'. See http://en.wikipedia.org/wiki/ISO_8601</Message>
        Example in basic format: 20160707T211822+0300
    */
	///creates a
	func HTTPDate(now:DateComponents, date: Date)->String {
//        let dayName:String = AWSAccount.calendar.shortWeekdaySymbols[now.weekday! - 1]
//        let monthShort:String = AWSAccount.calendar.shortMonthSymbols[now.month! - 1]
//        let year:String = "\(now.year!)"
//        let day:String = "\(now.day!)".prepadded("0", length: 2)
//        let hour:String = "\(now.hour!)".prepadded("0", length: 2)
//        let minute:String = "\(now.minute!)".prepadded("0", length: 2)
//        let second:String = "\(now.second!)".prepadded("0", length: 2)
//        return dayName + ", " + day + " " + monthShort + " " + year + " " + hour + ":" + minute + ":" + second + " GMT"
  
        // https://docs.aws.amazon.com/general/latest/gr/sigv4-date-handling.html
        /*
        The time stamp must be in UTC and in the following ISO 8601 format: YYYYMMDD'T'HHMMSS'Z'. For example, 20150830T123600Z is a valid time stamp. Do not include milliseconds in the time stamp.
        */
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
	}
	
	///returns sorted key-value tuples
	func canonicalHeaders()->[(String, String)] {
		let allHeaders = allHTTPHeaderFields ?? [:]
		var headerValues:[(String,String)] = allHeaders.map { (key, value) -> (String, String) in
			return (key.lowercased(), value.trimmingCharacters(in: .whitespaces))
		}
		headerValues = headerValues.filter({ (key0, _) -> Bool in
			return key0 == "host"
				|| key0 == "content-type"
				|| key0.hasPrefix("x-amz-")
		})
		if allHeaders["Host"] == nil, let host:String = url?.host {
			headerValues.append(("host",host))
		}
		headerValues.sort { $0.0 < $1.0 }
		return headerValues
		
	}
	
	
	mutating func canonicalRequestBeforePayload(urlQueryParams: Dictionary<String, String>? = nil)->(request:String, signedHeaders:String)? {
		let verb:String = httpMethod ?? "GET"
		guard var uriString:String = url?.path else { return nil } 	//TODO: "URI Encode"
		
        // 2/5/19; In case caller doesn't give trailing "/"
        if urlQueryParams != nil && uriString == "" {
            uriString = "/"
        }
        
        var queryString:String? = url?.query

        // 2/3/19; CGP; From https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html#signature-v4-test-suite-derived-creds, it seems this trailing "?" is not required or needed.
		// if queryString?.isEmpty == false {
		// 	uriString.append("?")
		// }
        
		guard let encodedURI:String = uriString.aws_uriEncoded(encodeSlash: false) else { return nil }
    
        func urlEncode(queryItems: [String]) -> String {
            let reconstituted:[String] = queryItems.map{
                $0.components(separatedBy: "=")
                    .compactMap{$0.aws_uriEncoded(encodeSlash: true)}
                    .joined(separator: "=")}
            return reconstituted.joined(separator: "&")
        }
        
        if let urlQueryParams = urlQueryParams {
            let queryItems:[String] = urlQueryParams.map { (key, value) in
                "\(key)=\(value)"
            }.sorted()
            queryString = urlEncode(queryItems: queryItems)
            self.url = URL(string: self.url!.absoluteString + "/?" + queryString!)
        }
		else if let queryLongString = queryString, !queryLongString.isEmpty  {
            // 2/3/19; CGP; Added sorting for query items. See https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
			let queryItems:[String] = queryLongString.components(separatedBy: "&").sorted()
			queryString = urlEncode(queryItems: queryItems)
		}
		
		let headerValues:[(String, String)] = canonicalHeaders()
		var headers:String = headerValues.map { (key, value) -> String in
			return key + ":" + value
			}.joined(separator: "\n")
		headers.append("\n")
		let signedHeaders:String = headerValues.map({$0.0}).joined(separator: ";")
		
		return ([verb, encodedURI, queryString ?? "", headers, signedHeaders].joined(separator: "\n"), signedHeaders)
	}
	
	
	mutating func canonicalRequest(signPayload:Bool, urlQueryParams: Dictionary<String, String>? = nil)->(request:String, signedHeaders:String)? {
		guard let (beforePayload, signedHeaders) = canonicalRequestBeforePayload(urlQueryParams: urlQueryParams) else { return nil }
		let hashedBody:String = signPayload ? sha256HashedBody.map { CryptoUtils.hexString(from: $0).lowercased() }
			?? "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855".lowercased()
                : "UNSIGNED-PAYLOAD"
		return (beforePayload + "\n" + hashedBody, signedHeaders)
	}
	
	
	var sha256HashedBody:[UInt8]? {
		if let bodyData = httpBody {
			return Digest(using: .sha256).update(data: bodyData)?.final()
		} else {
			return Digest(using: .sha256).update(string: "")?.final()
		}
	}
	
    // 2/3/19; Factored out, for testing.
	mutating func hashCanonicalRequest(signPayload:Bool, urlQueryParams: Dictionary<String, String>? = nil) -> (hashedRequest:String, signedHeaders:String)? {
        guard let (request, signedHeaders) = canonicalRequest(signPayload:signPayload, urlQueryParams: urlQueryParams) else { return nil }
        //print("canonical request = \(request)")
        let hashOfCanonicalRequest:[UInt8] = Digest(using: .sha256).update(string: request)?.final() ?? []
        let hexHash:String = CryptoUtils.hexString(from: hashOfCanonicalRequest)
        return (hashedRequest: hexHash, signedHeaders: signedHeaders)
    }
    
	mutating func stringToSign(account:AWSAccount, urlQueryParams: Dictionary<String, String>? = nil, now:Date, nowComponents:DateComponents, signPayload:Bool)->(string:String, signedHeaders:String)? {
		let timeString:String = HTTPDate(now: nowComponents, date: now)
  
        guard let (hashedRequest, signedHeaders) = hashCanonicalRequest(signPayload: signPayload, urlQueryParams: urlQueryParams) else {
            return nil
        }
		
        let scope = account.scope(now: nowComponents)
		return ("AWS4-HMAC-SHA256\n" + timeString + "\n" + scope + "\n" + hashedRequest, signedHeaders)
	}
	
    // 2/3/19; CGP; Factored out for testing.
    static func computeSignature(signingKey:[UInt8], stringToSign: String) -> String {
        let signature:[UInt8] = HMAC(using:HMAC.Algorithm.sha256, key: Data(signingKey)).update(byteArray: CryptoUtils.byteArray(from:stringToSign))!.final()
        let signatureHex:String = CryptoUtils.hexString(from: signature)
        return signatureHex
    }
    
	mutating func newAuthorizationHeader(account:AWSAccount, urlQueryParams: Dictionary<String, String>? = nil, now:Date, nowComponents:DateComponents, signPayload:Bool = false)->String? {
		guard let signingKey:[UInt8] = account.keyForSigning(now:nowComponents)
			,let (string, signedHeaders) = stringToSign(account:account, urlQueryParams: urlQueryParams, now:now, nowComponents:nowComponents, signPayload:signPayload)
			else { return nil }
		//print("string to sign = \(string)")
  
        let signatureHex = URLRequest.computeSignature(signingKey: signingKey, stringToSign: string)
		
        // 2/3/19; CGP; Added spaces after commas-- to be consistent with https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html#signature-v4-test-suite-example
		return "AWS4-HMAC-SHA256 Credential=\(account.credentialString(now:nowComponents)), SignedHeaders=\(signedHeaders), Signature=\(signatureHex)"
	}
	
}

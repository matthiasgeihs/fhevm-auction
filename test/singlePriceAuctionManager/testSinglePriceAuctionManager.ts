import { expect } from "chai";
import { ethers, network } from "hardhat";

import { createInstance } from "../instance";
import { FhevmInstance } from "fhevmjs/node";
import { getSigners, initSigners, Signers } from "../signers";
import { SinglePriceAuctionManager, TestToken } from "../../types";
import { reencryptEuint64 } from "../reencrypt";

describe("TestSinglePriceAuctionManager", function () {
  let signers: Signers
  let managerContract: SinglePriceAuctionManager
  let fhevm: FhevmInstance
  let sellToken: TestToken
  let paymentToken: TestToken

  before(async function () {
    await initSigners();
    signers = getSigners();
  });

  beforeEach(async function () {
    // Deploy manager contract and token contracts.
    const tokenFactory = await ethers.getContractFactory("TestToken");
    sellToken = await tokenFactory.connect(signers.alice).deploy("SellToken", "ST");
    paymentToken = await tokenFactory.connect(signers.alice).deploy("BuyToken", "BT");

    const managerContractFactory = await ethers.getContractFactory("SinglePriceAuctionManager");
    managerContract = await managerContractFactory.connect(signers.alice).deploy();

    await sellToken.waitForDeployment();
    await paymentToken.waitForDeployment();
    await managerContract.waitForDeployment();

    // Create fhEVM instance.
    fhevm = await createInstance();

    // Prefund accounts with tokens.
    await sellToken.mint(signers.alice.address, 1000);
    await paymentToken.mint(signers.bob.address, 1000);
    await paymentToken.mint(signers.carol.address, 1000);

    // Set contract allowances.
    {
      const input = fhevm.createEncryptedInput(await sellToken.getAddress(), signers.alice.address);
      input.add64(1000);
      const encryptedAmount = await input.encrypt();
      await sellToken.connect(signers.alice)["approve(address,bytes32,bytes)"](
        await managerContract.getAddress(),
        encryptedAmount.handles[0],
        encryptedAmount.inputProof,
      );
    }
    {
      const input = fhevm.createEncryptedInput(await paymentToken.getAddress(), signers.bob.address);
      input.add64(1000);
      const encryptedAmount = await input.encrypt();
      await paymentToken.connect(signers.bob)["approve(address,bytes32,bytes)"](
        await managerContract.getAddress(),
        encryptedAmount.handles[0],
        encryptedAmount.inputProof,
      );
    }
    {
      const input = fhevm.createEncryptedInput(await paymentToken.getAddress(), signers.carol.address);
      input.add64(1000);
      const encryptedAmount = await input.encrypt();
      await paymentToken.connect(signers.carol)["approve(address,bytes32,bytes)"](
        await managerContract.getAddress(),
        encryptedAmount.handles[0],
        encryptedAmount.inputProof,
      );
    }
  });

  it("test auction", async function () {
    // Alice offers 100 sell tokens.
    const auctionDuration = 10
    {
      const tx = await managerContract.connect(signers.alice).createAuction(
        auctionDuration,
        100,
        await sellToken.getAddress(),
        await paymentToken.getAddress(),
      )
      await tx.wait();
    }

    // Bob bids on 10 sell tokens for price 1.
    const auctionId = await managerContract.auctionCounter();
    {
      const input = fhevm.createEncryptedInput(await managerContract.getAddress(), signers.bob.address);
      input.add64(10); // quantity
      input.add64(1); // price
      const encryptedAmount = await input.encrypt();
      const tx = await managerContract.connect(signers.bob).placeBid(auctionId, encryptedAmount.handles[0], encryptedAmount.handles[1], encryptedAmount.inputProof)
      await tx.wait();
    }

    // Carol bids on 20 sell tokens for price 2.
    {
      const input = fhevm.createEncryptedInput(await managerContract.getAddress(), signers.carol.address);
      input.add64(20); // quantity
      input.add64(2); // price
      const encryptedAmount = await input.encrypt();
      const tx = await managerContract.connect(signers.carol).placeBid(auctionId, encryptedAmount.handles[0], encryptedAmount.handles[1], encryptedAmount.inputProof)
      await tx.wait();
    }

    // Advance time to auction end.
    await network.provider.send("evm_increaseTime", [auctionDuration]);

    // Dave ends auction.
    {
      const tx = await managerContract.connect(signers.dave).endAuction(auctionId)
      await tx.wait();
    }

    // Alice withdraws funds.
    {
      const tx = await managerContract.connect(signers.alice).claimTokens(auctionId)
      await tx.wait();

      // Alice's SellToken balance: 1000 - 100 + 70 = 970
      const balSellEncrypted = await sellToken.balanceOf(signers.alice)
      const balSell = await reencryptEuint64(
        signers.alice,
        fhevm,
        balSellEncrypted,
        await sellToken.getAddress(),
      );
      expect(balSell).to.equal(970)

      // Alice's BuyToken balance: (10 + 20) S * 1 B/S = 30 B
      const balBuyEncrypted = await paymentToken.balanceOf(signers.alice)
      const balBuy = await reencryptEuint64(
        signers.alice,
        fhevm,
        balBuyEncrypted,
        await paymentToken.getAddress(),
      );
      expect(balBuy).to.equal(30)
    }

    // Bob withdraws funds.
    {
      const tx = await managerContract.connect(signers.bob).claimTokens(auctionId)
      await tx.wait();

      // Bob's SellToken balance: 10 
      const balSellEncrypted = await sellToken.balanceOf(signers.bob)
      const balSell = await reencryptEuint64(
        signers.bob,
        fhevm,
        balSellEncrypted,
        await sellToken.getAddress(),
      );
      expect(balSell).to.equal(10)

      // Bob's BuyToken balance: 1000 - 10 = 990
      const balBuyEncrypted = await paymentToken.balanceOf(signers.bob)
      const balBuy = await reencryptEuint64(
        signers.bob,
        fhevm,
        balBuyEncrypted,
        await paymentToken.getAddress(),
      );
      expect(balBuy).to.equal(990)
    }

    // Carol withdraws funds.
    {
      const tx = await managerContract.connect(signers.carol).claimTokens(auctionId)
      await tx.wait();

      // Carol's SellToken balance: 20
      const balSellEncrypted = await sellToken.balanceOf(signers.carol)
      const balSell = await reencryptEuint64(
        signers.carol,
        fhevm,
        balSellEncrypted,
        await sellToken.getAddress(),
      );
      expect(balSell).to.equal(20)

      // Carol's BuyToken balance: 1000 - 20 * 1 = 980
      const balBuyEncrypted = await paymentToken.balanceOf(signers.carol)
      const balBuy = await reencryptEuint64(
        signers.carol,
        fhevm,
        balBuyEncrypted,
        await paymentToken.getAddress(),
      );
      expect(balBuy).to.equal(980)
    }
  });
});

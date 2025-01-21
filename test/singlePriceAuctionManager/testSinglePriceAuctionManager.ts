import { expect } from "chai";
import { ethers, network } from "hardhat";

// import { createInstance } from "../instance";
// import { FhevmInstance } from "fhevmjs/node";
import { getSigners, initSigners, Signers } from "../signers";
import { SinglePriceAuctionManager, TestToken } from "../../types";

describe("TestSinglePriceAuctionManager", function () {
  let signers: Signers
  let managerContract: SinglePriceAuctionManager
  // let fhevm: FhevmInstance
  let sellToken: TestToken
  let paymentToken: TestToken

  before(async function () {
    await initSigners();
    signers = getSigners();
  });

  beforeEach(async function () {
    // Deploy manager contract and token contracts.
    const tokenFactory = await ethers.getContractFactory("TestToken");
    sellToken = await tokenFactory.connect(signers.alice).deploy();
    paymentToken = await tokenFactory.connect(signers.alice).deploy();

    const managerContractFactory = await ethers.getContractFactory("SinglePriceAuctionManager");
    managerContract = await managerContractFactory.connect(signers.alice).deploy();

    await sellToken.waitForDeployment();
    await paymentToken.waitForDeployment();
    await managerContract.waitForDeployment();

    // // Create fhEVM instance.
    // fhevm = await createInstance();

    // Prefund accounts with tokens.
    await sellToken.mint(signers.alice.address, 1000);
    await paymentToken.mint(signers.bob.address, 1000);
    await paymentToken.mint(signers.carol.address, 1000);

    // Set contract allowances.
    await sellToken.connect(signers.alice).approve(await managerContract.getAddress(), 1000);
    await paymentToken.connect(signers.bob).approve(await managerContract.getAddress(), 1000);
    await paymentToken.connect(signers.carol).approve(await managerContract.getAddress(), 1000);
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
      const tx = await managerContract.connect(signers.bob).placeBid(auctionId, 10, 1)
      await tx.wait();
    }

    // Carol bids on 20 sell tokens for price 2.
    {
      const tx = await managerContract.connect(signers.carol).placeBid(auctionId, 20, 2)
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
      const balSell = await sellToken.balanceOf(signers.alice)
      expect(balSell).to.equal(970)

      // Alice's BuyToken balance: (10 + 20) S * 1 B / S = 30 B
      const balBuy = await paymentToken.balanceOf(signers.alice)
      expect(balBuy).to.equal(30)
    }

    // Bob withdraws funds.
    {
      const tx = await managerContract.connect(signers.bob).claimTokens(auctionId)
      await tx.wait();
    }

    // Carol withdraws funds.
    {
      const tx = await managerContract.connect(signers.carol).claimTokens(auctionId)
      await tx.wait();
    }
  });
});

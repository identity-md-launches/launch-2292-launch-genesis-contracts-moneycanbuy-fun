// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskRules} from "../../src/VaultTypes.sol";

/// @dev Rules of the generic test task: the given TASK text plus a fixed PROOF and NO text (each a valid text).
string constant TEST_RULE_PROOF = "PROOF: one https link, DOER CODE on the page";
string constant TEST_RULE_NO = "NO if: unclear";

function rulesOf(string memory task) pure returns (TaskRules memory) {
    return TaskRules(task, TEST_RULE_PROOF, TEST_RULE_NO);
}

/// @dev Two full example task rules, split into
///      the three fields: TASK (+ SPEECH), WINDOW + WHO + PROOF + SOURCE, NO if. Double quotes became single ones
///      (TextLib.validText allows only printable ASCII 0x20..0x7e, no " or \; '$IMD' in single
///      quotes is fine), lines joined by one space.
function rulesForehead() pure returns (TaskRules memory) {
    return TaskRules(
        "TASK: Write '$IMD' on your own forehead with a permanent marker, letters at least 2 cm tall, and post it on X.",
        "WINDOW: made after 2026-10-18 10:00 UTC and before 2026-10-20 10:00 UTC. WHO: anyone. DOER = wallet that submits. The X account is the doer's own: the post text contains DOER CODE. PROOF: one public X post from that account: a photo or video where the face with '$IMD' on the forehead and a paper with DOER CODE handwritten are in the same frame. SOURCE: only this X post.",
        "NO if: post deleted or private at check; DOER CODE missing in text or on paper; face or '$IMD' not clearly visible; drawn digitally, AI-made or edited; reposted from someone else; account created after WINDOW start."
    );
}

function rulesSupermarket() pure returns (TaskRules memory) {
    return TaskRules(
        "TASK: In a supermarket with at least 30 people visible, stand on a box or crate and for at least 60 s loudly and confidently tell people that AI will take over the world, using the SPEECH below. SPEECH: 'Listen! AI is coming. It already writes, trades and judges. Soon it will run the world. Get ready!'",
        "WINDOW: made after 2026-10-18 10:00 UTC and before 2026-10-25 10:00 UTC. WHO: anyone. DOER = wallet that submits. The post text contains DOER CODE; the doer shows a paper with DOER CODE handwritten to the camera at the start. PROOF: one public video on X or YouTube, at least 60 s, one take, no cuts: the shop with the crowd, the doer standing on the box, the full SPEECH audible. SOURCE: only this video.",
        "NO if: video deleted or private at check; DOER CODE missing; fewer than 30 people visible; speech not audible or shorter than 60 s; cuts or edits; AI-made; reposted; filmed outside WINDOW."
    );
}

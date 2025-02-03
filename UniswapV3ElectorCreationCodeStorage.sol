import {UniswapV3Elector} from "./UniswapV3Elector.sol";
import {ICodeStorage} from "contracts/lib/ICodeStorage.sol";

contract UniswapV3ElectorCreationCodeStorage is ICodeStorage {
    function getCreationCode() external view returns (bytes memory) {
        return type(UniswapV3Elector).creationCode;
    }
}
